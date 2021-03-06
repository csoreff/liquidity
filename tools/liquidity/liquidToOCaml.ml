(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2017       .                                          *)
(*    Fabrice Le Fessant, OCamlPro SAS <fabrice@lefessant.net>            *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

(* The version that will be required to compile the generated files. *)
let output_version = "0.151"

(*
type storage = ...
let contract
      (parameter : timestamp)
      (storage: storage )
      : unit * storage =
       ...
 *)

open Asttypes
open Longident
open Parsetree
open LiquidTypes

open Ast_helper

let loc txt = { loc = !default_loc; txt }
let lid s = loc (Longident.parse s)

let typ_constr s args = Typ.constr (lid s) args

let cpt_abbrev = ref 0
let abbrevs = Hashtbl.create 101
let rev_abbrevs = Hashtbl.create 101
let get_abbrev ty = let s, _, _ = Hashtbl.find abbrevs ty in s
let add_abbrev s ty caml_ty =
  incr cpt_abbrev;
  let s =
    try Hashtbl.find rev_abbrevs s; s ^ string_of_int !cpt_abbrev
    with Not_found -> s in
  Hashtbl.add abbrevs ty (s, caml_ty, !cpt_abbrev);
  Hashtbl.replace rev_abbrevs s ();
  typ_constr s []

let clean_abbrevs () = cpt_abbrev := 0; Hashtbl.clear abbrevs
let list_caml_abbrevs_in_order () =
  Hashtbl.fold (fun ty v l -> (ty, v) :: l) abbrevs []
  |> List.fast_sort (fun (_, (_, _, i1)) (_, (_, _, i2)) -> i1 - i2)
  |> List.map (fun (ty, (s, caml_ty, _)) -> s, caml_ty)

let rec convert_type ?(abbrev=true) ?name ty =
  match ty with
  | Ttez ->  typ_constr "tez" []
  | Tunit -> typ_constr "unit" []
  | Ttimestamp -> typ_constr "timestamp" []
  | Tint -> typ_constr "int" []
  | Tnat -> typ_constr "nat" []
  | Tbool -> typ_constr "bool" []
  | Tkey -> typ_constr "key" []
  | Tkey_hash -> typ_constr "key_hash" []
  | Tsignature -> typ_constr "signature" []
  | Tstring -> typ_constr "string" []
  | Tsum (name, _)
  | Trecord (name, _) -> typ_constr name []
  | Tfail -> assert false
  | _ ->
    try typ_constr (get_abbrev ty) []
    with Not_found ->
    let caml_ty, t_name = match ty with
    | Ttez | Tunit | Ttimestamp | Tint | Tnat | Tbool
    | Tkey | Tkey_hash | Tsignature | Tstring
    | Tfail | Trecord _ | Tsum _ -> assert false
    | Ttuple args ->
      Typ.tuple (List.map (convert_type ~abbrev) args), "pair_t"
    | Tor (x,y) ->
      typ_constr "variant" [convert_type ~abbrev x; convert_type ~abbrev y], "variant_t"
    | Tcontract (x,y) ->
      typ_constr "contract" [convert_type ~abbrev x;convert_type ~abbrev y], "contract_t"
    | Tlambda (x,y) ->
      Typ.arrow Nolabel (convert_type ~abbrev x) (convert_type ~abbrev y), "lambda_t"
    | Tclosure ((x,e),r) ->
      Typ.arrow Nolabel (convert_type ~abbrev x) (convert_type ~abbrev r), "closure_t"
    | Tmap (x,y) ->
      typ_constr "map" [convert_type ~abbrev x;convert_type ~abbrev y], "map_t"
    | Tset x ->
      typ_constr "set" [convert_type ~abbrev x], "set_t"
    | Tlist x ->
      typ_constr "list" [convert_type ~abbrev x], "list_t"
    | Toption x ->
      typ_constr "option" [convert_type ~abbrev x], "option_t"
    in
    let name = match name with
      | Some name -> name
      | None -> t_name
    in
    if abbrev then
      add_abbrev name ty caml_ty
    else
      caml_ty



let rec convert_const expr =
  match expr with
  | CInt n -> Exp.constant (Const.integer (LiquidPrinter.liq_of_integer n))
  | CNat n -> Exp.constant (Const.integer ~suffix:'p'
                                          (LiquidPrinter.liq_of_integer n))
  | CString s -> Exp.constant (Const.string s)
  | CUnit -> Exp.construct (lid "()") None
  | CBool false -> Exp.construct (lid "false") None
  | CBool true -> Exp.construct (lid "true") None
  | CNone -> Exp.construct (lid "None") None
  | CSome x -> Exp.construct (lid "Some")
                             (Some (convert_const x))
  | CLeft x -> Exp.construct (lid "Left")
                             (Some (convert_const x))
  | CRight x -> Exp.construct (lid "Right")
                             (Some (convert_const x))
  | CConstr (c, CUnit) -> Exp.construct (lid c) None
  | CConstr (c, x) -> Exp.construct (lid c)
                        (Some (convert_const x))
  | CTuple args -> Exp.tuple (List.map convert_const args)
  | CTez n -> Exp.constant (Const.float ~suffix:'\231'
                                        (LiquidPrinter.liq_of_tez n))
  | CTimestamp s -> Exp.constant (Pconst_integer (s, Some '\232'))
  | CKey_hash n -> Exp.constant (Pconst_integer (n, Some '\233'))
  | CKey n -> Exp.constant (Pconst_integer (n, Some '\234'))
  | CSignature n -> Exp.constant (Pconst_integer (n, Some '\235'))
  | CContract n -> Exp.constant (Pconst_integer (n, Some '\236'))

  | CList [] -> Exp.construct (lid "[]") None
  | CList (head :: tail) ->
     Exp.construct (lid "::") (Some
                                 (Exp.tuple [convert_const head;
                                             convert_const (CList tail)]))
  | CSet [] ->
     Exp.construct (lid "Set") None
  | CSet list ->
     Exp.construct (lid "Set")
                   (Some (convert_const (CList list)))
  | CMap [] ->
     Exp.construct (lid "Map") None
  | CMap list ->
     let args =
       List.fold_left (fun tail (key,value) ->
           Exp.construct (lid "::")
                         (Some
                            (Exp.tuple
                               [
                                 Exp.tuple [
                                     convert_const key;
                                     convert_const value;
                                   ];
                                 tail
                         ]))
         ) (Exp.construct (lid "[]") None) list
     in
     Exp.construct (lid "Map") (Some args)
  | CRecord labels ->
    Exp.record
      (List.map (fun (f, x) -> lid f, convert_const x) labels)
      None

let rec convert_code expr =
  match expr.desc with
  | Var (name, _, fields) ->
     List.fold_left (fun exp field ->
         Exp.field exp (lid field)
       ) (Exp.ident (lid name)) fields
  | If (cond, ifthen, { desc = Const(_loc, Tunit, CUnit) }) ->
     Exp.ifthenelse (convert_code cond)
                    (convert_code ifthen) None
  | If (cond, ifthen, ifelse) ->
     Exp.ifthenelse (convert_code cond)
                    (convert_code ifthen) (Some (convert_code ifelse))
  | Seq (x, { desc = Const(_loc, Tunit, CUnit) }) ->
     convert_code x

  | Seq (x, y) ->
     Exp.sequence (convert_code x) (convert_code y)

  | Const (_loc, ty, cst) -> begin
      match ty with
      | Tint
      | Tnat
      | Tstring
      | Tunit
      | Ttimestamp
      | Ttez
      | Tbool
      | Tsignature
      | Tkey
      | Tkey_hash -> convert_const cst
      | _ ->
         Exp.constraint_ (convert_const cst) (convert_type ty)
    end
  | Let (var, _loc, exp, body) ->
     Exp.let_ Nonrecursive
              [ Vb.mk (Pat.var (loc var))
                      (convert_code exp)]
              (convert_code body)
  | Lambda (arg_name, arg_type, _loc, body, _res_type) ->
     Exp.fun_ Nolabel None
              (Pat.constraint_
                 (Pat.var (loc arg_name))
                 (convert_type ~name:(arg_name^"_t") arg_type))
              (convert_code body)

  | Closure _ -> assert false

  | Apply (Prim_Cons, _loc, args) ->
     Exp.construct (lid "::")
                   (Some (Exp.tuple (List.map convert_code args)))
  | Apply (Prim_Some, _loc, [arg]) ->
     Exp.construct (lid "Some") (Some (convert_code arg))
  | Apply (Prim_tuple, _loc, args) ->
     Exp.tuple (List.map convert_code args)
  | Apply (Prim_exec, _loc, [x; f]) ->
    Exp.apply (convert_code f) [Nolabel, convert_code x]

  | Apply (prim, _loc, args) ->
     let prim_name =
       try
         LiquidTypes.string_of_primitive prim
       with Not_found -> assert false
     in
     Exp.apply (Exp.ident (lid prim_name))
               (List.map (fun arg ->
                    Nolabel,
                    convert_code arg) args)

  | Failwith (s, _loc) ->
    Exp.apply (Exp.ident (lid "Current.failwith"))
      [Nolabel, Exp.constant (Const.string s)]

  | SetVar (name, _, fields, exp) -> begin
      match List.rev fields with
        field :: fields ->
        let fields = List.rev fields in
        Exp.setfield
          (List.fold_left (fun exp field ->
               Exp.field exp (lid field)
             ) (Exp.ident (lid name)) fields)
          (lid field)
          (convert_code exp)
      | _ -> assert false
    end

  | MatchOption (exp, _loc, ifnone, some_pat, ifsome) ->
     Exp.match_ (convert_code exp)
                [
                  Exp.case (Pat.construct (lid "None") None)
                           (convert_code ifnone);
                  Exp.case (Pat.construct (lid "Some")
                                          (Some (Pat.var (loc some_pat))))
                           (convert_code ifsome);
                ]

  | MatchNat (exp, _loc, p, ifplus, m, ifminus) ->
    Exp.extension (loc "nat", PStr [
        Str.eval (
          Exp.match_ (convert_code exp)
                [
                  Exp.case (Pat.construct (lid "Plus")
                              (Some (Pat.var (loc p))))
                    (convert_code ifplus);
                  Exp.case (Pat.construct (lid "Minus")
                              (Some (Pat.var (loc m))))
                    (convert_code ifminus);
                ])
      ])

  | MatchList (exp, _loc, head_pat, tail_pat, ifcons, ifnil) ->
     Exp.match_ (convert_code exp)
                [
                  Exp.case (Pat.construct (lid "[]") None)
                           (convert_code ifnil);
                  Exp.case (Pat.construct (lid "::")
                                          (Some (
                                               Pat.tuple
                                                 [Pat.var (loc head_pat);
                                                  Pat.var (loc tail_pat)]
                           )))
                           (convert_code ifcons);
                ]

  | LetTransfer ( var_storage, var_result,
                  _loc,
                  contract_exp,
                  amount_exp,
                  storage_exp,
                  arg_exp,
                  body_exp) ->
     Exp.let_ Nonrecursive [
                Vb.mk (Pat.tuple [
                           Pat.var (loc var_result);
                           Pat.var (loc var_storage);
                      ])
                      (Exp.apply (Exp.ident (lid "Contract.call"))
                                 [
                                   Nolabel, convert_code contract_exp;
                                   Nolabel, convert_code amount_exp;
                                   Nolabel, convert_code storage_exp;
                                   Nolabel, convert_code arg_exp;
                      ])
              ]
              (convert_code body_exp)

  | Loop (var_arg, _loc, body_exp, arg_exp) ->
     Exp.apply (Exp.ident (lid "Loop.loop"))
               [
                 Nolabel, Exp.fun_ Nolabel None
                                   (Pat.var (loc var_arg))
                                   (convert_code body_exp);
                 Nolabel, convert_code arg_exp
               ]

  | Fold ((Prim_map_iter|Prim_set_iter|Prim_list_iter as prim),
          var_arg, _loc,
          { desc = Apply(Prim_exec, _, [ { desc = Var (iter_arg, _, []) }; f])},
          arg_exp, _acc_exp) when iter_arg = var_arg ->
     Exp.apply (Exp.ident (lid (LiquidTypes.string_of_fold_primitive prim)))
               [ Nolabel, convert_code f;
                 Nolabel, convert_code arg_exp;
               ]
  | Fold ((Prim_map_iter|Prim_set_iter|Prim_list_iter as prim),
          var_arg, _loc, body_exp, arg_exp, _acc_exp) ->
     Exp.apply (Exp.ident (lid (LiquidTypes.string_of_fold_primitive prim)))
               [
                 Nolabel, Exp.fun_ Nolabel None
                                   (Pat.var (loc var_arg))
                                   (convert_code body_exp);
                 Nolabel, convert_code arg_exp;
               ]
  | Fold (prim, var_arg, _loc,
          { desc = Apply(Prim_exec, _, [ { desc = Var (iter_arg, _, []) }; f])},
          arg_exp,
          acc_exp) when iter_arg = var_arg ->
     Exp.apply (Exp.ident (lid (LiquidTypes.string_of_fold_primitive prim)))
               [
                 Nolabel, convert_code f;
                 Nolabel, convert_code arg_exp;
                 Nolabel, convert_code acc_exp;
               ]
  | Fold (prim, var_arg, _loc, body_exp, arg_exp, acc_exp) ->
     Exp.apply (Exp.ident (lid (LiquidTypes.string_of_fold_primitive prim)))
               [
                 Nolabel, Exp.fun_ Nolabel None
                                   (Pat.var (loc var_arg))
                                   (convert_code body_exp);
                 Nolabel, convert_code arg_exp;
                 Nolabel, convert_code acc_exp;
               ]

  | Record (_loc, fields) ->
     Exp.record (List.map (fun (name, exp) ->
                     lid name, convert_code exp
                   ) fields) None

  | MatchVariant (arg, _loc, cases) ->
     Exp.match_ (convert_code arg)
       (List.map (function
            | CAny, exp ->
              Exp.case (Pat.any ()) (convert_code exp)
            | CConstr (constr, var_args), exp ->
              Exp.case
                (Pat.construct (lid constr)
                   (match var_args with
                    | [] -> None
                    | [var_arg] ->
                      Some (Pat.var (loc var_arg))
                    | var_args ->
                      Some
                        (Pat.tuple (List.map
                                      (fun var_arg ->
                                         Pat.var (loc var_arg)
                                      ) var_args))
                   ))
                (convert_code exp)
          ) cases)

  | Constructor (_loc, Constr id, { desc = Const (_loc', Tunit, CUnit) } ) ->
     Exp.construct (lid id) None
  | Constructor (_loc, Constr id, arg) ->
     Exp.construct (lid id) (Some (convert_code arg))
  | Constructor (_loc, Left right_ty, arg) ->
     Exp.constraint_
       (Exp.construct (lid "Left")
                      (Some
                         (convert_code arg)))
       (Typ.constr (lid "variant")
                   [Typ.any (); convert_type right_ty])
  | Constructor (_loc, Right left_ty, arg) ->
     Exp.constraint_
       (Exp.construct (lid "Right")
                      (Some
                         (convert_code arg)))
       (Typ.constr (lid "variant")
                   [convert_type left_ty; Typ.any ()])
  | Constructor (_loc, Source (from_ty, to_ty), arg) ->
     Exp.constraint_
       (Exp.construct (lid "Source") None)
       (Typ.constr (lid "contract")
                   [convert_type from_ty;
                    convert_type to_ty])

let structure_of_contract contract =
  clean_abbrevs ();
  let storage_caml = convert_type ~name:"storage" contract.storage in
  ignore (convert_type ~name:"parameter" contract.parameter);
  ignore (convert_type ~name:"return" contract.return);
  let code = convert_code contract.code in
  let contract_caml = Str.extension (
      { txt = "entry"; loc = !default_loc },
      PStr    [
        Str.value Nonrecursive
          [
            Vb.mk (Pat.var (loc "main"))
              (Exp.fun_ Nolabel None
                 (Pat.constraint_
                    (Pat.var (loc "parameter"))
                    (convert_type contract.parameter)
                 )
                 (Exp.fun_ Nolabel None
                    (Pat.constraint_
                       (Pat.var (loc "storage"))
                       storage_caml
                    )
                    (Exp.constraint_
                       code (Typ.tuple [convert_type contract.return;
                                        storage_caml]))
                 ))
          ]
      ])
  in
  let version_caml = Str.extension (
      { txt = "version"; loc = !default_loc },
      PStr [
        Str.eval
          (Exp.constant (Const.float output_version))
      ])
  in
  let types_caml =
    list_caml_abbrevs_in_order ()
    |> List.map (fun (txt, manifest) ->
                  Str.type_ Recursive [
                  Type.mk ~manifest { txt; loc = !default_loc }
                ])
  in

  [ version_caml ] @ types_caml @ [ contract_caml ]

let string_of_structure = LiquidOCamlPrinter.string_of_structure

let translate_expression = convert_code

let string_of_expression = LiquidOCamlPrinter.string_of_expression

let convert_type ?(abbrev=true) ty = convert_type ~abbrev ty
