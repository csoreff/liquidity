(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2017       .                                          *)
(*    Fabrice Le Fessant, OCamlPro SAS <fabrice@lefessant.net>            *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

open LiquidTypes


(* let string_of_pre pre = *)
(*   LiquidPrinter.Michelson.string_of_code (LiquidEmit.emit_code (SEQ pre)) *)

(* Try to simplify Michelson with peepholes optims: mostly, move
   DIP_DROPs backwards to decrease the size of the stack. *)

let ii ~loc ins = { ins; loc; loc_name = None }
let lii = ii

let drops ~loc n = LiquidMisc.list_init n (fun _ -> ii ~loc DROP)

let dip_drop ~loc (a,b)=
  if a = 0 then drops ~loc b else [ii ~loc (DIP_DROP(a,b))]

let rec simplify_pre ({ ins } as e) =
  { e with
    ins =
      match ins with
      | SEQ expr -> SEQ (simplify_seq expr)
      | IF (e1, e2) -> IF (simplify_pre e1, simplify_pre e2)
      | IF_NONE (e1, e2) -> IF_NONE (simplify_pre e1, simplify_pre e2)
      | IF_LEFT (e1, e2) -> IF_LEFT (simplify_pre e1, simplify_pre e2)
      | IF_CONS (e1, e2) -> IF_CONS (simplify_pre e1, simplify_pre e2)
      | DIP (n, e) -> DIP (n, simplify_pre e)
      | LOOP e -> LOOP (simplify_pre e)
      | LAMBDA (arg_type, res_type, e) ->
        LAMBDA (arg_type, res_type, simplify_pre e)
      | _ -> ins
  }

and simplify_seq exprs =
  match exprs with
  | [] -> []
  | ({ins=ANNOT _} as a) :: ({ins=FAIL _} as f):: exprs -> [a; f]
  | e :: exprs ->
    let e = simplify_pre e in
    match e.ins with
    | FAIL _ -> [e]
    | _ ->
      let exprs =  simplify_seq exprs in
      simplify_step e exprs

and simplify_step e exprs =
  let ii = ii ~loc:e.loc in
  match e.ins, exprs with

  | SEQ e, exprs -> simplify_steps e exprs
  | DIP_DROP(n,0), exprs -> exprs
  | DIP (0, e), exprs -> simplify_step e exprs
  | DUP _, {ins=DROP} :: exprs -> exprs
  | PUSH _, ({ins=FAIL _} as fail) :: _ -> [fail]
  | FAIL _, _ -> [e]

  | IF(i1,i2), exprs ->
     begin
       match i1.ins, i2.ins,exprs with
       | SEQ ({ins=DROP} :: e1), SEQ ({ins=DROP} :: e2), exprs ->
         simplify_stepi ~loc:e.loc (DIP_DROP(1,1))
           (simplify_stepi ~loc:e.loc (IF ( lii ~loc:i1.loc @@ SEQ e1,
                                 lii ~loc:i2.loc @@ SEQ e2 )) exprs)

       | SEQ ({ ins=DIP_DROP(n,m)} :: e1),
         SEQ ({ ins=DIP_DROP(n',m')} :: e2),
         exprs when n=n'
         ->
          let min_m = min m m' in
          simplify_stepi ~loc:e.loc (DIP_DROP(n,min_m))
            (simplify_stepi ~loc:e.loc
               (IF
                  (lii ~loc:i1.loc @@ SEQ (simplify_stepi ~loc:i1.loc (DIP_DROP(n,m-min_m)) e1),
                   lii ~loc:i2.loc @@ SEQ (simplify_stepi ~loc:i2.loc (DIP_DROP(n,m'-min_m)) e2)
                  )) exprs)

       | SEQ [{ins=FAIL _} as fail],
         SEQ [{ins=PUSH _}],
         {ins=DROP} :: exprs ->
         simplify_step
           (ii @@ IF (lii ~loc:i1.loc @@ SEQ [fail],
                      lii ~loc:i2.loc @@ SEQ [])) exprs

       | SEQ [{ins=FAIL _} as fail],
         SEQ [],
         {ins=DROP} :: exprs ->
          simplify_stepi ~loc:e.loc (DIP_DROP(1,1))
            (simplify_stepi ~loc:e.loc
               (IF (lii ~loc:i1.loc @@ SEQ [fail],
                    lii ~loc:i2.loc @@ SEQ [])) exprs)

       | SEQ [{ins=FAIL _} as fail],
         SEQ [],
         {ins=DIP_DROP(n,m)} :: exprs ->
          simplify_stepi ~loc:e.loc (DIP_DROP(n+1,m))
                        (simplify_stepi ~loc:e.loc
                           (IF (lii ~loc:i1.loc @@ SEQ [fail],
                                lii ~loc:i2.loc @@ SEQ [])) exprs)

       | _ -> e :: exprs
     end

  (* takes nothing, add one item on stack : 0 -> 1 *)
  | (PUSH _ | NOW | BALANCE | SELF | SOURCE _ | AMOUNT | STEPS_TO_QUOTA
     | LAMBDA _
    ),
    {ins=DIP_DROP (n,m); loc} :: exprs ->
     if n > 0 then
       dip_drop ~loc (n-1,m) @ simplify_step e exprs
     else
       if m = 1 then
         exprs
       else
         lii ~loc (DIP_DROP (n,m-1)) :: exprs

  | (PUSH _ | NOW | BALANCE | SELF | SOURCE _ | AMOUNT | STEPS_TO_QUOTA
     | LAMBDA _
    ), {ins=DROP} :: exprs -> exprs


  (* takes one item on stack, creates one :  1 -> 1 *)
  | (CAR | CDR | CDAR _ | CDDR _
     | LE | LT | GE | GT | NEQ | EQ | SOME
     | MANAGER | H | NOT | ABS | INT | NEG | LEFT _ | RIGHT _
     | EDIV | LSL | LSR
    ),
    {ins=DIP_DROP (n,m); loc} :: exprs when n > 0 ->
     simplify_stepi ~loc (DIP_DROP (n,m))
                   (simplify_step e exprs)

  | (CAR | CDR | CDAR _ | CDDR _
     | LE | LT | GE | GT | NEQ | EQ | SOME
     | MANAGER | H | NOT | ABS | INT | NEG | LEFT _ | RIGHT _
     | EDIV | LSL | LSR
    ),
    {ins=DROP; loc} :: exprs -> lii ~loc DROP :: exprs


  (* takes two items on stack, creates one : 2 -> 1 *)
  | (PAIR | ADD | SUB | COMPARE | GET | CONCAT | MEM
     | CONS | CHECK_SIGNATURE | EXEC | MAP
     | OR | AND | XOR | MUL),
    {ins=DIP_DROP (n,m); loc} :: exprs when n > 0 ->
     simplify_stepi ~loc (DIP_DROP (n+1,m))
                   (simplify_step e exprs)

  (* takes three items on stack, creates one *)
  | (UPDATE | REDUCE),
    {ins=DIP_DROP (n,m); loc} :: exprs when n > 0 ->
     simplify_stepi ~loc (DIP_DROP (n+2,m))
       (simplify_step e exprs)

  (* takes four items on stack, creates one : 4 -> 1 *)
  | (CREATE_ACCOUNT),
    {ins=DIP_DROP (n,m); loc} :: exprs when n > 0 ->
     simplify_stepi ~loc (DIP_DROP (n+3,m))
       (simplify_step e exprs)

  (* takes two items on stack, creates two : 2 -> 2 *)
  | SWAP,
    {ins=DIP_DROP (n,m); loc} :: exprs when n > 1 ->
     simplify_stepi ~loc (DIP_DROP (n,m))
       (simplify_step e exprs)


  | DIP (n,e), {ins=DROP; loc} :: exprs when n > 0 ->
     ii DROP :: simplify_stepi ~loc (DIP(n-1,e)) exprs


  | DIP_DROP (n,m), {ins=DIP_DROP (n',m')} :: exprs when n = n' ->
     ii (DIP_DROP (n, m+m')) :: exprs

  | PUSH (ty', CList tail), {ins=PUSH (ty, head)} :: {ins=CONS; loc} :: exprs
    when ty' = Tlist ty ->
    let loc = LiquidLoc.merge e.loc loc in
    simplify_stepi ~loc (PUSH (ty', CList (head :: tail))) exprs

  | DUP 1, {ins=DIP_DROP (1,1)} :: exprs -> exprs
  | DUP 1, {ins=DIP_DROP (1,m)} :: exprs when m > 1 ->
     simplify_stepi ~loc:e.loc (DIP_DROP (1, m-1)) exprs

  | DUP 2, {ins=DIP_DROP (1,1); loc} :: exprs ->
    simplify_stepi ~loc DROP (simplify_stepi ~loc:e.loc (DUP 1) exprs)

  | DUP 2, {ins=DIP_DROP (1,2); loc} :: exprs ->
     simplify_stepi ~loc DROP exprs

  | DUP 3, {ins=DIP_DROP (2,2); loc} :: exprs ->
    simplify_stepi ~loc:e.loc SWAP
      (simplify_stepi ~loc DROP
         (simplify_stepi ~loc:e.loc SWAP exprs))

  | DUP 2, {ins=SWAP} :: {ins=DROP; loc} :: exprs ->
     simplify_stepi ~loc DROP
       (simplify_stepi ~loc:e.loc (DUP 1) exprs)

  | DUP 2, {ins=DIP_DROP (2,1)} :: exprs ->
    simplify_stepi ~loc:e.loc SWAP exprs

  | DUP n, {ins=DIP_DROP(m,p); loc} :: exprs ->
     (* let before = DUP n :: DIP_DROP(m,p) :: exprs in *)
     let after =
       if n<m then
         if m =1 then
           drops ~loc p @ (simplify_stepi ~loc:e.loc (DUP n) exprs)
         else
           simplify_stepi ~loc (DIP_DROP(m-1,p))
             (simplify_stepi ~loc:e.loc (DUP n) exprs)
       else
         if n >= m+p then
           if m = 1 then
             drops ~loc p @ (simplify_stepi ~loc:e.loc (DUP (n-p)) exprs)
           else
             simplify_stepi ~loc (DIP_DROP (m-1,p))
               (simplify_stepi ~loc:e.loc (DUP (n-p)) exprs)
         else
           if p = 1 then
             {e with ins=DUP n} :: lii ~loc (DIP_DROP(m,p)) :: exprs
           else
             let x = n-m in
             let y = p -x - 1 in
             let code =
               simplify_stepi ~loc:e.loc (DUP(n-x))
                 (simplify_stepi ~loc (DIP_DROP(m,1)) exprs)
             in
             let code =
               if y > 0 then
                 simplify_stepi ~loc (DIP_DROP(m,y)) code
               else code
             in
             let code =
               if x > 0 then
                 dip_drop ~loc (m-1, x) @ code
               else code
             in
             code

     in
     (*
     let before_s = string_of_pre before in
     let after_s = string_of_pre after in
     Printf.eprintf "BEFORE:\n%s\nAFTER:\n%s\n" before_s after_s;
      *)
     after
  | _ -> e :: exprs

and simplify_stepi ~loc i code = simplify_step (ii ~loc i) code

and simplify_steps list tail =
  let rec iter list_rev tail =
    match list_rev with
      [] -> tail
    | e :: list ->
       iter list (simplify_step e tail)
  in
  iter (List.rev list) tail

let simplify contract =
  { contract with code = simplify_pre contract.code }
