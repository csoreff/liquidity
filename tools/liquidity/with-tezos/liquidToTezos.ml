(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2017       .                                          *)
(*    Fabrice Le Fessant, OCamlPro SAS <fabrice@lefessant.net>            *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

open LiquidTypes
open Micheline

type loc_table = (int * (LiquidTypes.location * string option)) list

type tezos_code = (unit,string) Micheline.node

let ii ~loc ins = { ins; loc; loc_name  = None }

let loc_of_many (l : loc_michelson list) = match l, List.rev l with
  | [], _ | _, [] -> LiquidLoc.noloc
  | first :: _, last :: _ -> LiquidLoc.merge first.loc last.loc

let prim ~loc name args annot =
  let annot = match annot with
    | Some s -> Some ("@" ^ s)
    | None -> None
  in
  Micheline.Prim(loc, name, args, annot)

let seq ~loc exprs annot =
  let annot = match annot with
    | Some s -> Some ("@" ^ s)
    | None -> None
  in
  Micheline.Seq(loc, exprs, annot)

let prim_type ~loc name args = Micheline.Prim(loc, name, args, None)

let rec convert_const ~loc expr =
  match expr with
  | CInt n -> Micheline.Int (loc, LiquidPrinter.mic_of_integer n)
  | CString s -> Micheline.String (loc, s)
  | CUnit -> Micheline.Prim(loc, "Unit", [], None)
  | CBool true -> Micheline.Prim(loc, "True", [], None)
  | CBool false -> Micheline.Prim(loc, "False", [], None)
  | CNone -> Micheline.Prim(loc, "None", [], None)

  | CSome x -> Micheline.Prim(loc, "Some", [convert_const ~loc x], None)
  | CLeft x -> Micheline.Prim(loc, "Left", [convert_const ~loc x], None)
  | CRight x -> Micheline.Prim(loc, "Right", [convert_const ~loc x], None)

  | CTuple [] -> assert false
  | CTuple [_] -> assert false
  | CTuple [x;y] ->
     Micheline.Prim(loc, "Pair", [convert_const ~loc x;
                                  convert_const ~loc y], None)
  | CTuple (x :: y) ->
     Micheline.Prim(loc, "Pair", [convert_const ~loc x;
                                  convert_const ~loc (CTuple y)], None)
  | CList args -> Micheline.Prim(loc, "List",
                                   List.map (convert_const ~loc) args, None)

  | CMap args ->
     Micheline.Prim(loc, "Map",
                      List.map (fun (x,y) ->
                          Micheline.Prim(loc, "Item", [convert_const ~loc x;
                                                       convert_const ~loc y], None
                                          ))
                               args, None)
  | CSet args -> Micheline.Prim(loc, "Set",
                                  List.map (convert_const ~loc) args, None)
  | CNat n -> Micheline.Int (loc, LiquidPrinter.mic_of_integer n)
  | CTez n -> Micheline.String (loc, LiquidPrinter.mic_of_tez n)
           (*
  | CTez tez
    |CKey _|
   | CSignature _|CLeft _|CRight _)
            *)
  | CTimestamp s -> Micheline.String (loc, s)
  | CKey s -> Micheline.String (loc, s)
  | CKey_hash s -> Micheline.String (loc, s)
  | CContract s -> Micheline.String (loc, s)
  | CSignature s -> Micheline.String (loc, s)

  | _ ->
    LiquidLoc.raise_error ~loc:(fst loc) "to-tezos: unimplemented const:\n%s%!"
      (LiquidPrinter.Michelson.string_of_const expr)


let rec convert_type ~loc expr =
  match expr with
  | Tunit -> prim_type ~loc "unit" []
  | Ttimestamp -> prim_type ~loc "timestamp" []
  | Ttez -> prim_type ~loc "tez" []
  | Tint -> prim_type ~loc "int" []
  | Tnat -> prim_type ~loc "nat" []
  | Tbool -> prim_type ~loc "bool" []
  | Tkey -> prim_type ~loc "key" []
  | Tkey_hash -> prim_type ~loc "key_hash" []
  | Tsignature -> prim_type ~loc "signature" []
  | Tstring -> prim_type ~loc "string" []
  | Ttuple [x] -> assert false
  | Ttuple [] -> assert false
  | Ttuple [x;y] -> prim_type ~loc "pair" [convert_type ~loc x; convert_type ~loc y]
  | Ttuple (x :: tys) ->
     prim_type ~loc "pair" [convert_type ~loc x; convert_type ~loc (Ttuple tys)]
  | Tor (x,y) -> prim_type ~loc "or" [convert_type ~loc x; convert_type ~loc y]
  | Tcontract (x,y) -> prim_type ~loc "contract" [convert_type ~loc x;
                                             convert_type ~loc y]
  | Tlambda (x,y) -> prim_type ~loc "lambda" [convert_type ~loc x;
                                         convert_type ~loc y]
  | Tclosure ((x,e),r) ->
    convert_type ~loc (Ttuple [Tlambda (Ttuple [x; e], r); e ]);
  | Tmap (x,y) -> prim_type ~loc "map" [convert_type ~loc x;convert_type ~loc y]
  | Tset x -> prim_type ~loc "set" [convert_type ~loc x]
  | Tlist x -> prim_type ~loc "list" [convert_type ~loc x]
  | Toption x -> prim_type ~loc "option" [convert_type ~loc x]
  | Tfail | Trecord _ | Tsum _ -> assert false

let rec convert_code expand expr =
  let name = expr.loc_name in
  let ii = ii ~loc:expr.loc in
  let seq = seq ~loc:(expr.loc, None) in
  let gprim = prim in
  let prim = prim ~loc:(expr.loc, None) in
  let convert_type = convert_type ~loc:(expr.loc, None) in
  let convert_const = convert_const ~loc:(expr.loc, None) in
  match expr.ins with
  | ANNOT a -> seq [] (Some a)
  | SEQ exprs -> seq (List.map (convert_code expand) exprs) name

  | FAIL s -> gprim ~loc:(expr.loc, s) "FAIL" [] name

  | DROP -> prim "DROP" [] name
  | DIP (0, arg) -> assert false
  | DIP (1, arg) -> prim "DIP" [ convert_code expand arg ] name
  | DIP (n, arg) ->
    if expand then
      prim "DIP" [ convert_code expand @@ ii @@
                   SEQ [{ expr with ins = DIP(n-1, arg)}]
                 ] None
    else
      prim (Printf.sprintf "D%sP" (String.make n 'I'))
        [ convert_code expand arg ] name
  | CAR -> prim "CAR" [] name
  | CDR -> prim "CDR" [] name
  | SWAP -> prim "SWAP" [] name
  | IF (x,y) ->
    prim "IF" [convert_code expand x; convert_code expand y] name
  | IF_NONE (x,y) ->
    prim "IF_NONE" [convert_code expand x; convert_code expand y] name
  | IF_LEFT (x,y) ->
    prim "IF_LEFT" [convert_code expand x; convert_code expand y] name
  | IF_CONS (x,y) ->
    prim "IF_CONS" [convert_code expand x; convert_code expand y] name
  | NOW -> prim "NOW" [] name
  | PAIR -> prim "PAIR" [] name
  | BALANCE -> prim "BALANCE" [] name
  | SUB -> prim "SUB" [] name
  | ADD -> prim "ADD" [] name
  | MUL -> prim "MUL" [] name
  | NEQ -> prim "NEQ" [] name
  | EQ -> prim "EQ" [] name
  | LT -> prim "LT" [] name
  | LE -> prim "LE" [] name
  | GT -> prim "GT" [] name
  | GE -> prim "GE" [] name
  | GET -> prim "GET" [] name
  | UPDATE -> prim "UPDATE" [] name
  | MEM -> prim "MEM" [] name
  | SOME -> prim "SOME" [] name
  | MANAGER -> prim "MANAGER" [] name
  | SOURCE (ty1,ty2) ->
     prim "SOURCE" [convert_type ty1; convert_type ty2] name
  | MAP -> prim "MAP" [] name
  | OR -> prim "OR" [] name
  | LAMBDA (ty1, ty2, expr) ->
     prim "LAMBDA" [convert_type ty1; convert_type ty2; convert_code expand expr] name
  | REDUCE -> prim "REDUCE" [] name
  | COMPARE -> prim "COMPARE" [] name
  | PUSH (Tunit, CUnit) -> prim "UNIT" [] name
  | TRANSFER_TOKENS -> prim "TRANSFER_TOKENS" [] name
  | PUSH (ty, cst) -> prim "PUSH" [ convert_type ty;
                                    convert_const cst ] name
  | H -> prim "H" [] name
  | HASH_KEY -> prim "HASH_KEY" [] name
  | CHECK_SIGNATURE -> prim "CHECK_SIGNATURE" [] name
  | CONCAT -> prim "CONCAT" [] name
  | EDIV -> prim "EDIV" [] name
  | EXEC -> prim "EXEC" [] name
  | MOD -> prim "MOD" [] name
  | DIV -> prim "DIV" [] name
  | AMOUNT -> prim "AMOUNT" [] name
                   (*
  | prim "EMPTY_MAP" [ty1; ty2] ->
     PUSH (Tmap (convert_type ty1, convert_type ty2), CMap [])
  | prim "NONE" [ty] ->
     PUSH (Toption (convert_type ty), CNone)
                    *)
  | LEFT ty ->
     prim "LEFT" [convert_type ty] name
  | CONS -> prim "CONS" [] name
  | LOOP loop -> prim "LOOP" [convert_code expand loop] name
  | ITER body -> prim "ITER" [convert_code expand body] name
  | RIGHT ty ->
     prim "RIGHT" [convert_type ty] name
  | INT -> prim "INT" [] name
  | ABS -> prim "ABS" [] name
  | DUP 1 -> prim "DUP" [] name
  | DUP 0 -> assert false
  | DUP n ->
    if expand then
      convert_code expand @@ ii @@
      SEQ [
        ii @@ DIP(1, ii @@ SEQ [ii @@ DUP(n-1)]);
        { expr with ins = SWAP }
      ]
    else
      prim (Printf.sprintf "D%sP" (String.make n 'U')) [] name

  | SELF -> prim "SELF" [] name
  | STEPS_TO_QUOTA -> prim "STEPS_TO_QUOTA" [] name
  | CREATE_ACCOUNT -> prim "CREATE_ACCOUNT" [] name
  | CREATE_CONTRACT -> prim "CREATE_CONTRACT" [] name

  | XOR -> prim "XOR" [] name
  | AND -> prim "AND" [] name
  | NOT -> prim "NOT" [] name
  | NEG -> prim "NEG" [] name
  | LSL -> prim "LSL" [] name
  | LSR -> prim "LSR"  [] name
  | DIP_DROP (ndip, ndrop) ->
    convert_code expand @@
    ii @@ DIP (ndip, ii @@ SEQ (LiquidMisc.list_init ndrop (fun _ -> ii DROP)))

  | CDAR 0 -> convert_code expand { expr with ins = CAR }
  | CDDR 0 -> convert_code expand { expr with ins = CDR }
  | CDAR n ->
    if expand then
      convert_code expand @@ ii @@
      SEQ (LiquidMisc.list_init n (fun _ -> ii CDR) @ [{ expr with ins = CAR }])
    else prim (Printf.sprintf "C%sAR" (String.make n 'D')) [] name
  | CDDR n ->
    if expand then
      convert_code expand @@ ii @@
      SEQ (LiquidMisc.list_init n (fun _ -> ii CDR) @ [{ expr with ins = CDR }])
    else prim (Printf.sprintf "C%sDR" (String.make n 'D')) [] name
  | SIZE -> prim "SIZE" [] name
  | DEFAULT_ACCOUNT -> prim "DEFAULT_ACCOUNT" [] name


let convert_contract ~expand c =
  let loc = LiquidLoc.noloc in
  let ret_type = convert_type ~loc c.return in
  let arg_type = convert_type ~loc c.parameter in
  let storage_type = convert_type ~loc c.storage in
  let code = convert_code expand c.code in
  let r = Micheline.Prim(loc, "return", [ret_type], None) in
  let p = Micheline.Prim(loc, "parameter", [arg_type], None) in
  let s = Micheline.Prim(loc, "storage", [storage_type], None) in
  let c = Micheline.Prim((loc, None), "code", [code], None) in

  let mr, tr = Micheline.extract_locations r in
  let mp, tp = Micheline.extract_locations p in
  let ms, ts = Micheline.extract_locations s in
  let code_loc_offset =
    List.length tr + List.length tp + List.length ts + 1 in

  let mc, loc_table = Micheline.extract_locations c in
  let loc_table = List.map (fun (i, l) ->
      i + code_loc_offset, l
    ) loc_table in

  if !LiquidOptions.verbosity > 1 then
    List.iter (fun (i, (l, s)) ->
        match s with
        | None -> Format.eprintf "%d -> %a@." i LiquidLoc.print_loc l
        | Some s -> Format.eprintf "%d -> %a -> %S@." i LiquidLoc.print_loc l s
      ) loc_table;

  [mr; mp; ms; mc], loc_table

let print_program comment_of_loc ppf (c, loc_table) =
  let c = List.map
      (Micheline.inject_locations (fun l ->
           (* { Micheline_printer.comment = Some (string_of_int l) } *)
           { Micheline_printer.comment = None }
         )) c in
  List.iter (fun node ->
      Format.fprintf ppf "%a;@."
        Micheline_printer.print_expr_unwrapped node
    ) c


let string_of_contract c =
  let ppf = Format.str_formatter in
  print_program (fun _ -> None) ppf (c, []);
  Format.flush_str_formatter ()

let line_of_contract c =
  let ppf = Format.str_formatter in
  let ffs = Format.pp_get_formatter_out_functions ppf () in
  let new_ffs =
    { ffs with
      Format.out_newline = (fun () -> ffs.Format.out_spaces 1);
      (* Format.out_indent = (fun _ -> ()); *)
    } in
  Format.pp_set_formatter_out_functions ppf new_ffs;
  print_program (fun _ -> None) ppf (c, []);
  let s = Format.flush_str_formatter () in
  Format.pp_set_formatter_out_functions ppf ffs;
  s

let contract_encoding =
  Micheline.canonical_encoding Data_encoding.string |> Data_encoding.list

let json_of_contract c =
  Data_encoding.Json.construct contract_encoding c
  |> Data_encoding_ezjsonm.to_string


let contract_of_json j =
  (* let open Error_monad in *)
  Data_encoding_ezjsonm.from_string j
  |> Data_encoding.Json.destruct contract_encoding

let contract_of_ezjson ezj =
  Data_encoding.Json.destruct contract_encoding ezj

let const_encoding =
  Micheline.canonical_encoding Data_encoding.string
  (* Micheline.erased_encoding 0 Data_encoding.string *)

let json_of_const c =
  Data_encoding.Json.construct const_encoding c
  |> Data_encoding_ezjsonm.to_string

let const_of_json j =
  Data_encoding_ezjsonm.from_string j
  |> Data_encoding.Json.destruct const_encoding

let const_of_ezjson ezj =
  Data_encoding.Json.destruct const_encoding ezj

(* let read_file = FileString.read_file *)

let read_file filename =
  let lines = ref [] in
  let chan = open_in filename in
  begin try
    while true; do
      lines := input_line chan :: !lines
    done;
    with
      End_of_file -> close_in chan
  end;
  !lines |> List.rev |> String.concat "\n"

let read_tezos_file filename =
  let s = read_file filename in
  match LiquidFromTezos.contract_of_string filename s with
  | Some (code, loc_table) ->
     Printf.eprintf "Program %S parsed\n%!" filename;
     code, loc_table
  | None ->
     Printf.eprintf "Errors parsing in %S\n%!" filename;
     exit 2



let convert_const c =
  convert_const ~loc:(LiquidLoc.noloc, None) c |> Micheline.strip_locations

    (*

let contract_amount = ref "1000.00"
let contract_arg = ref (Micheline.Prim(0, "Unit", [], debug))
let contract_storage = ref (Micheline.Prim(0, "Unit", [], debug))

let context = ref None

let get_context () =
  match !context with
  | Some ctxt -> ctxt
  | None ->
     let (level : int32) = 1l in
     let (timestamp : int64) = 1L in
     let (fitness : MBytes.t list) = [] in
     let (ctxt : Context.t) = Context.empty in
     match
       Storage.prepare ~level ~timestamp ~fitness ctxt
     with
     | Error _ -> assert false
     | Ok (ctxt, _bool) ->
        context := Some ctxt;
        ctxt

let execute_contract_file filename =
  assert false
         (*
  let contract, contract_hash, _ = read_tezos_file filename in

  let origination = Contract.initial_origination_nonce contract_hash in
  let destination = Contract.originated_contract origination in

  (* TODO: change that. Why do we need a Source opcode in Michelson ? *)
  let source = destination in

  let ctxt = get_context () in

  let (amount : Tez.t) =
    match Tez_repr.of_string !contract_amount with
    | None -> assert false
    | Some amount -> amount in
  let (storage : Micheline.storage) = {
      Micheline.storage_type = contract.Script.storage_type;
      Micheline.storage = !contract_storage;
    } in
  let (arg : Micheline.expr) = !contract_arg in
  let (qta : int) = 1000 in

  match
    Script_interpreter.execute origination source destination ctxt
                               storage contract amount
                               arg qta
  with
  | Ok (new_storage, result, qta, ctxt, origination) ->
     let ppf = Format.str_formatter in
     let noloc = fun _ -> None in
     Format.fprintf ppf "Result:\n";
     Client_proto_programs.print_expr noloc ppf result;
     Format.fprintf ppf "@.";
     Format.fprintf ppf "Storage:\n";
     Client_proto_programs.print_expr noloc ppf new_storage;
     Format.fprintf ppf "@.";
     let s = Format.flush_str_formatter () in
     Printf.printf "%s\n%!" s;
     contract_storage := new_storage

  | Error errors ->
     Printf.eprintf "%d Errors executing %S\n%!"
                    (List.length errors) filename;
     List.iter (fun error ->
         Format.eprintf "%a" Tezos_context.pp error
       ) errors;
     Tezos_context.pp_print_error Format.err_formatter errors;
     Format.fprintf Format.err_formatter "@.";

     exit 2
          *)
          *)

let arg_list work_done = [
    (*
    "--exec", Arg.String (fun s ->
                  work_done := true;
                  execute_contract_file s),
    "FILE.tz Execute Tezos file FILE.tz";
    "--load-arg", Arg.String (fun s ->
                      let content = FileString.read_file s in
                      match LiquidFromTezos.data_of_string content with
                      | None -> assert false
                      | Some data -> contract_arg := data),
    "FILE Use data from file as argument";
    "--load-storage", Arg.String (fun s ->
                          let content = FileString.read_file s in
                          match LiquidFromTezos.data_of_string content with
                          | None -> assert false
                          | Some data -> contract_storage := data),
    "FILE Use data from file as initial storage";
    "--amount", Arg.String (fun s -> contract_amount := s),
    "NNN.00 Number of Tez sent";
     *)
  ]

(* force linking not anymore ?
let execute = Script_interpreter.execute
 *)
