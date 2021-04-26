(* Compile (typed!) RaQL expressions into DIL expressions *)
open Batteries
open RamenHelpersNoLog
open RamenHelpers
open RamenLog
open Dessser
module DE = DessserExpressions
module DT = DessserTypes
module DS = DessserStdLib
module DU = DessserCompilationUnit
module E = RamenExpr
module Lang = RamenLang
module N = RamenName
module T = RamenTypes
open DE.Ops

(*$inject
  open Batteries *)

(*
 * Helpers
 *)

let mn_of_t = function
  | DT.Value mn -> mn
  | t -> invalid_arg ("mn_of_t for type "^ DT.to_string t)

let print_r_env oc =
  pretty_list_print (fun oc (k, v) ->
    Printf.fprintf oc "%a=>%a"
      E.print_binding_key k
      (DE.print ~max_depth:2) v
  ) oc

let without_optimization f =
  let prev_optimize = !DE.optimize in
  DE.optimize := false ;
  let r = f () in
  DE.optimize := prev_optimize ;
  r

(* Construct a value of some user type that's a sum type: *)
let make_usr_type_sum n i d =
  (* Retrieve the sum type from the user type: *)
  match DT.get_user_type n |> DT.develop_value_type with
  | Sum mns ->
      DE.Ops.construct mns i d
  | _ ->
      invalid_arg "make_usr_sum: not a sum"

(*
 * Conversions
 *)

(* Convert a non-nullable value to the given value-type.
 * Beware that the returned expression might be nullable (for instance when
 * converting a string to a number). *)
(* TODO: move in dessser.StdLib as a "cast" function *)
let rec conv ?(depth=0) ~to_ l d =
  let conv = conv ~depth:(depth+1) in
  let map_items d mn1 mn2 =
    map_ d (
      DE.func1 ~l (DT.Value mn1)
        (conv_maybe_nullable ~depth:(depth+1) ~to_:mn2)) in
  let from = (mn_of_t (DE.type_of l d)).DT.vtyp in
  if DT.value_type_eq from to_ then d else
  (* A null can be cast to whatever. Actually, type-checking will type nulls
   * arbitrarily. *)
  if match d with DE.E0 (Null _) -> true | _ -> false then null to_ else
  match from, to_ with
  (* Any cast from a user type to its implementation is a NOP, and the other
   * way around too: *)
  | Usr { def ; _ }, to_ when def = to_ ->
      d
  | from, Usr { def ; _ } when def = from ->
      d
  | DT.Mac (I8 | I16 | I24 | I32 | I40 | I48 | I56 | I64 | I128 |
            U8 | U16 | U24 | U32 | U40 | U48 | U56 | U64 | U128),
    DT.Mac String -> string_of_int_ d
  | DT.Mac (I8 | I16 | I24 | I32 | I40 | I48 | I56 | I64 | I128 |
            U8 | U16 | U24 | U32 | U40 | U48 | U56 | U64 | U128),
    DT.Mac Float -> to_float d
  | DT.Mac U8, DT.Mac Bool -> bool_of_u8 d
  | DT.Mac (I8 | I16 | I24 | I32 | I40 | I48 | I56 | I64 | I128 |
            U16 | U24 | U32 | U40 | U48 | U56 | U64 | U128 | Float),
    DT.Mac Bool -> bool_of_u8 (conv ~to_:(DT.Mac U8) l d)
  | Mac String, Mac Float -> float_of_string_ d
  | Mac String, Mac Char -> char_of_string d
  | Mac String, Mac I8 -> i8_of_string d
  | Mac String, Mac I16 -> i16_of_string d
  | Mac String, Mac I24 -> i24_of_string d
  | Mac String, Mac I32 -> i32_of_string d
  | Mac String, Mac I40 -> i40_of_string d
  | Mac String, Mac I48 -> i48_of_string d
  | Mac String, Mac I56 -> i56_of_string d
  | Mac String, Mac I64 -> i64_of_string d
  | Mac String, Mac I128 -> i128_of_string d
  | Mac String, Mac U8 -> u8_of_string d
  | Mac String, Mac U16 -> u16_of_string d
  | Mac String, Mac U24 -> u24_of_string d
  | Mac String, Mac U32 -> u32_of_string d
  | Mac String, Mac U40 -> u40_of_string d
  | Mac String, Mac U48 -> u48_of_string d
  | Mac String, Mac U56 -> u56_of_string d
  | Mac String, Mac U64 -> u64_of_string d
  | Mac String, Mac U128 -> u128_of_string d
  | Mac Float, Mac String -> string_of_float_ d
  | Mac Char, Mac U8 -> u8_of_char d
  | Mac U8, Mac Char -> char_of_u8 d
  | Mac Char, Mac String -> string_of_char d
  | Mac (I8 | I16 | I24 | I32 | I40 | I48 | I56 | I64 | I128 |
         U8 | U16 | U24 | U32 | U40 | U48 | U56 | U64 | U128 | Float),
    Mac I8 -> to_i8 d
  | Mac (I8 | I16 | I24 | I32 | I40 | I48 | I56 | I64 | I128 |
         U8 | U16 | U24 | U32 | U40 | U48 | U56 | U64 | U128 | Float),
    Mac I16 -> to_i16 d
  | Mac (I8 | I16 | I24 | I32 | I40 | I48 | I56 | I64 | I128 |
         U8 | U16 | U24 | U32 | U40 | U48 | U56 | U64 | U128 | Float),
    Mac I24 -> to_i24 d
  | Mac (I8 | I16 | I24 | I32 | I40 | I48 | I56 | I64 | I128 |
         U8 | U16 | U24 | U32 | U40 | U48 | U56 | U64 | U128 | Float),
    Mac I32 -> to_i32 d
  | Mac (I8 | I16 | I24 | I32 | I40 | I48 | I56 | I64 | I128 |
         U8 | U16 | U24 | U32 | U40 | U48 | U56 | U64 | U128 | Float),
    Mac I40 -> to_i40 d
  | Mac (I8 | I16 | I24 | I32 | I40 | I48 | I56 | I64 | I128 |
         U8 | U16 | U24 | U32 | U40 | U48 | U56 | U64 | U128 | Float),
    Mac I48 -> to_i48 d
  | Mac (I8 | I16 | I24 | I32 | I40 | I48 | I56 | I64 | I128 |
         U8 | U16 | U24 | U32 | U40 | U48 | U56 | U64 | U128 | Float),
    Mac I56 -> to_i56 d
  | Mac (I8 | I16 | I24 | I32 | I40 | I48 | I56 | I64 | I128 |
         U8 | U16 | U24 | U32 | U40 | U48 | U56 | U64 | U128 | Float),
    Mac I64 -> to_i64 d
  | Mac (I8 | I16 | I24 | I32 | I40 | I48 | I56 | I64 | I128 |
         U8 | U16 | U24 | U32 | U40 | U48 | U56 | U64 | U128 | Float),
    Mac I128 -> to_i128 d
  | Mac (I8 | I16 | I24 | I32 | I40 | I48 | I56 | I64 | I128 |
         U8 | U16 | U24 | U32 | U40 | U48 | U56 | U64 | U128 | Float),
    Mac U8 -> to_u8 d
  | Mac (I8 | I16 | I24 | I32 | I40 | I48 | I56 | I64 | I128 |
         U8 | U16 | U24 | U32 | U40 | U48 | U56 | U64 | U128 | Float),
    Mac U16 -> to_u16 d
  | Mac (I8 | I16 | I24 | I32 | I40 | I48 | I56 | I64 | I128 |
         U8 | U16 | U24 | U32 | U40 | U48 | U56 | U64 | U128 | Float),
    Mac U24 -> to_u24 d
  | Mac (I8 | I16 | I24 | I32 | I40 | I48 | I56 | I64 | I128 |
         U8 | U16 | U24 | U32 | U40 | U48 | U56 | U64 | U128 | Float),
    Mac U32 -> to_u32 d
  | Mac (I8 | I16 | I24 | I32 | I40 | I48 | I56 | I64 | I128 |
         U8 | U16 | U24 | U32 | U40 | U48 | U56 | U64 | U128 | Float),
    Mac U40 -> to_u40 d
  | Mac (I8 | I16 | I24 | I32 | I40 | I48 | I56 | I64 | I128 |
         U8 | U16 | U24 | U32 | U40 | U48 | U56 | U64 | U128 | Float),
    Mac U48 -> to_u48 d
  | Mac (I8 | I16 | I24 | I32 | I40 | I48 | I56 | I64 | I128 |
         U8 | U16 | U24 | U32 | U40 | U48 | U56 | U64 | U128 | Float),
    (Mac U56 | Usr { name = "Eth" ; _ }) -> to_u56 d
  | Mac (I8 | I16 | I24 | I32 | I40 | I48 | I56 | I64 | I128 |
         U8 | U16 | U24 | U32 | U40 | U48 | U56 | U64 | U128 | Float),
    Mac U64 -> to_u64 d
  | Mac (I8 | I16 | I24 | I32 | I40 | I48 | I56 | I64 | I128 |
         U8 | U16 | U24 | U32 | U40 | U48 | U56 | U64 | U128 | Float),
    Mac U128 -> to_u128 d
  (* Bools can be (explicitly) converted into numbers: *)
  | Mac Bool, Mac U8 -> u8_of_bool d
  | Mac Bool, Mac U16 -> to_u16 (u8_of_bool d)
  | Mac Bool, Mac U24 -> to_u24 (u8_of_bool d)
  | Mac Bool, Mac U32 -> to_u32 (u8_of_bool d)
  | Mac Bool, Mac U40 -> to_u40 (u8_of_bool d)
  | Mac Bool, Mac U48 -> to_u48 (u8_of_bool d)
  | Mac Bool, Mac U56 -> to_u56 (u8_of_bool d)
  | Mac Bool, Mac U64 -> to_u64 (u8_of_bool d)
  | Mac Bool, Mac U128 -> to_u128 (u8_of_bool d)
  | Mac Bool, Mac I8 -> to_i8 (u8_of_bool d)
  | Mac Bool, Mac I16 -> to_i16 (u8_of_bool d)
  | Mac Bool, Mac I24 -> to_i24 (u8_of_bool d)
  | Mac Bool, Mac I32 -> to_i32 (u8_of_bool d)
  | Mac Bool, Mac I40 -> to_i40 (u8_of_bool d)
  | Mac Bool, Mac I48 -> to_i48 (u8_of_bool d)
  | Mac Bool, Mac I56 -> to_i56 (u8_of_bool d)
  | Mac Bool, Mac I64 -> to_i64 (u8_of_bool d)
  | Mac Bool, Mac I128 -> to_i128 (u8_of_bool d)
  | Mac Bool, Mac Float -> to_float (u8_of_bool d)
  (* Specialized version for lst/vec of chars that return the
   * string composed of those chars rather than an enumeration: *)
  | Vec (_, { vtyp = Mac Char ; _ }), Mac String
  | Lst { vtyp = Mac Char ; _ }, Mac String ->
      conv_charseq ~depth:(depth+1) (cardinality d) l d
  | Vec _, Mac String
  | Lst _, Mac String ->
      conv_list ~depth:(depth+1) (cardinality d) l d
  | Mac Bool, Mac String ->
      if_ ~cond:d ~then_:(string "true") ~else_:(string "false")
  | Usr { name = ("Ip4" | "Ip6" | "Ip") ; _ }, Mac String ->
      string_of_ip d
  | (Usr { name = "Ip4" ; _ } | Mac U32), Usr { name = "Ip" ; _ } ->
      make_usr_type_sum "Ip" 0 d
  | (Usr { name = "Ip6" ; _ } | Mac U128), Usr { name = "Ip" ; _ } ->
      make_usr_type_sum "Ip" 1 d
  | Usr { name = "Cidr4" ; _ }, Usr { name = "Cidr" ; _ } ->
      make_usr_type_sum "Cidr" 0 d
  | Usr { name = "Cidr6" ; _ }, Usr { name = "Cidr" ; _ } ->
      make_usr_type_sum "Cidr" 1 d
  | Vec (d1, mn1), Vec (d2, mn2) when d1 = d2 ->
      map_items d mn1 mn2
  | Lst mn1, Lst mn2 ->
      map_items d mn1 mn2
  (* TODO: Also when d2 < d1, and d2 > d1 extending with null as long as mn2 is
   * nullable *)
  | Vec (_, mn1), Lst mn2 ->
      let d = list_of_vec d in
      map_items d mn1 mn2
  (* Groups are typed as lists: *)
  | Set (_, mn1), Lst mn2 ->
      let d = list_of_set d in
      map_items d mn1 mn2
  (* TODO: other types to string *)
  | _ ->
      Printf.sprintf2 "Not implemented: Cast from %a to %a of expression %a"
        DT.print_value_type from
        DT.print_value_type to_
        (DE.print ~max_depth:3) d |>
      failwith

and conv_list ?(depth=0) length_e l src =
  (* We use a one entry vector as a ref cell: *)
  let_ ~name:"dst_" ~l (make_vec [ string "[" ]) (fun _l dst ->
    let set v = set_vec (u32_of_int 0) dst v
    and get () = get_vec (u32_of_int 0) dst in
    let idx_t = DT.(Value (required (Mac U32))) in
    let cond =
      DE.func1 ~l idx_t (fun _l i -> lt i length_e)
    and body =
      DE.func1 ~l idx_t (fun _l i ->
        let s =
          conv_maybe_nullable ~depth:(depth+1) ~to_:DT.(required (Mac String))
                              l (get_vec i src) in
        seq [ set (append_string (get ()) s) ;
              add i (u32_of_int 1) ]) in
    seq [ ignore_ (loop_while ~init:(u32_of_int 0) ~cond ~body) ;
          set (append_string (get ()) (string "]")) ;
          get () ])

and conv_charseq ?(depth=0) length_e l src =
  (* We use a one entry vector as a ref cell: *)
  let_ ~name:"dst_" ~l (make_vec [ string "" ]) (fun _l dst ->
    let set v = set_vec (u32_of_int 0) dst v
    and get () = get_vec (u32_of_int 0) dst in
    let idx_t = DT.(Value (required (Mac U32))) in
    let cond =
      DE.func1 ~l idx_t (fun _l i -> lt i length_e)
    and body =
      DE.func1 ~l idx_t (fun _l i ->
        let s =
          conv_maybe_nullable ~depth:(depth+1) ~to_:DT.(required (Mac Char))
                              l (get_vec i src) in
        seq [ set (append_string (get ()) (string_of_char s)) ;
              add i (u32_of_int 1) ]) in
    seq [ ignore_ (loop_while ~init:(u32_of_int 0) ~cond ~body) ;
          get () ])

and conv_maybe_nullable ?(depth=0) ~to_ l d =
  !logger.debug "%sConverting into %a: %a"
    (indent_of depth)
    DT.print_maybe_nullable to_
    (DE.print ?max_depth:None) d ;
  let conv = conv ~depth:(depth+1) ~to_:to_.DT.vtyp in
  let from = mn_of_t (DE.type_of l d) in
  let is_const_null =
    match d with DE.E0 (Null _) -> true | _ -> false in
  let if_null def =
    if is_const_null then def else
    let_ ~name:"nullable_to_not_nullable_" ~l d (fun d_env d ->
      if_
        ~cond:(is_null d)
        ~then_:def
        ~else_:(conv d_env (force d))) in
  (* Beware that [conv] can return a nullable expression: *)
  match from.DT.nullable, to_.DT.nullable with
  | false, false ->
      !logger.debug "%s...from not nullable to not nullable" (indent_of depth) ;
      let d' = conv l d in
      if (mn_of_t (DE.type_of l d')).DT.nullable then
        force ~what:"conv from not nullable to not nullable" d'
      else d'
  | true, false ->
      !logger.debug "%s...from nullable to not nullable" (indent_of depth) ;
      (match to_.DT.vtyp with
      | DT.(Mac String) ->
          if_null (string "NULL")
      | DT.(Mac Char) ->
          if_null (char '?')
      | _ ->
          let d' =
            conv l (force ~what:"conv from nullable to not nullable" d) in
          if (mn_of_t (DE.type_of l d')).DT.nullable then
            force ~what:"conv from nullable to not nullable (2)" d'
          else d')
  | false, true ->
      !logger.debug "%s...from not nullable to nullable" (indent_of depth) ;
      let d' = conv l d in
      if (mn_of_t (DE.type_of l d')).DT.nullable then d'
                                                 else not_null d'
  | true, true ->
      !logger.debug "%s...from nullable to nullable" (indent_of depth) ;
      if is_const_null then null to_.DT.vtyp else
      let_ ~name:"conv_mn_x_" ~l d (fun d_env x ->
        if_ ~cond:(is_null x)
            ~then_:(
              let x_vtyp = (mn_of_t (DE.type_of d_env x)).DT.vtyp in
              if DT.value_type_eq x_vtyp to_.DT.vtyp then
                x
              else
                null to_.DT.vtyp)
            ~else_:(conv_maybe_nullable ~depth:(depth+1) ~to_ d_env (force x)))

(* If [d] is nullable, then return it. If it's a not nullable value type,
 * then make it nullable: *)
let ensure_nullable ~d_env d =
  match DE.type_of d_env d with
  | DT.Value { nullable = false ; _ } -> not_null d
  | DT.Value { nullable = true ; _ } -> d
  | t -> invalid_arg ("ensure_nullable on "^ DT.to_string t)

let rec constant mn v =
  let bad_type () =
    Printf.sprintf2 "Invalid type %a for literal %a"
      DT.print_maybe_nullable mn
      T.print v |>
    failwith
  in
  match v with
  | T.VNull -> null mn.DT.vtyp
  | VUnit -> unit
  | VFloat f -> float f
  | VString s -> string s
  | VBool b -> bool b
  | VChar c -> char c
  | VU8 n -> u8 n
  | VU16 n -> u16 n
  | VU24 n -> u24 n
  | VU32 n -> u32 n
  | VU40 n -> u40 n
  | VU48 n -> u48 n
  | VU56 n -> u56 n
  | VU64 n -> u64 n
  | VU128 n -> u128 n
  | VI8 n -> i8 n
  | VI16 n -> i16 n
  | VI24 n -> i24 n
  | VI32 n -> i32 n
  | VI40 n -> i40 n
  | VI48 n -> i48 n
  | VI56 n -> i56 n
  | VI64 n -> i64 n
  | VI128 n -> i128 n
  | VEth n -> u48 n
  | VIpv4 i -> u32 i
  | VIpv6 i -> u128 i
  | VIp (RamenIp.V4 i) ->
      (match T.ip with
      | DT.Usr { def = Sum alts ; _ } ->
          construct alts 0 (constant (snd alts.(0)) (VIpv4 i))
      | _ -> assert false)
  | VIp (RamenIp.V6 i) ->
      (match T.ip with
      | DT.Usr { def = Sum alts ; _ } ->
          construct alts 1 (constant (snd alts.(1)) (VIpv6 i))
      | _ -> assert false)
  | VCidrv4 (i, m) ->
      make_rec [ "ip", u32 i ; "mask", u8 m ]
  | VCidrv6 (i, m) ->
      make_rec [ "ip", u128 i ; "mask", u8 m ]
  | VCidr (RamenIp.Cidr.V4 i_m) ->
      (match T.cidr with
      | DT.Usr { def = Sum alts ; _ } ->
          construct alts 0 (constant (snd alts.(0)) (VCidrv4 i_m))
      | _ -> assert false)
  | VCidr (RamenIp.Cidr.V6 i_m) ->
      (match T.cidr with
      | DT.Usr { def = Sum alts ; _ } ->
          construct alts 1 (constant (snd alts.(1)) (VCidrv6 i_m))
      | _ -> assert false)
  (* Although there are not much constant literal compound values in RaQL
   * (instead there are literal *expressions*, which individual items are
   * typed), it's actually possible to translate them thanks to the passed
   * type [mn]: *)
  | VTup vs ->
      (match mn.vtyp with
      | DT.Tup mns ->
          if Array.length mns <> Array.length vs then bad_type () ;
          make_tup (List.init (Array.length mns) (fun i ->
            constant mns.(i) vs.(i)))
      | _ ->
          bad_type ())
  | VVec vs ->
      (match mn.vtyp with
      | DT.Vec (d, mn) ->
          if d <> Array.length vs then bad_type () ;
          make_vec (List.init d (fun i -> constant mn vs.(i)))
      | _ ->
          bad_type ())
  | VLst vs ->
      (match mn.vtyp with
      | DT.Lst mn ->
          make_lst mn (List.init (Array.length vs) (fun i ->
            constant mn vs.(i)))
      | _ ->
          bad_type ())
  | VRec vs ->
      (match mn.vtyp with
      | DT.Rec mns ->
          if Array.length mns <> Array.length vs then bad_type () ;
          make_rec (Array.map (fun (n, mn) ->
            match Array.find (fun (n', _) -> n = n') vs with
            | exception Not_found ->
                bad_type ()
            | _, v ->
                n, constant mn v
          ) mns |> Array.to_list)
      | _ ->
          bad_type ())
  | VMap _ ->
      invalid_arg "constant: not for VMaps"

(*
 * States
 *
 * Stateful operators (aka aggregation functions aka unpure functions) need a
 * state that, although it is not materialized in RaQL, is remembered from one
 * input to the next and passed along to the operator so it can either update
 * it, or compute the final value when an output is due (finalize).
 * Technically, there is also a third required function: the init function that
 * returns the initial value of the state.
 *
 * The only way state appear in RaQL is via the "locally" vs "globally"
 * keywords, which actually specify whether the state of a stateful function is
 * stored with the group or globally.
 *
 * Dessser has no stateful operators, so this mechanism has to be implemented
 * from scratch. To help with that, dessser has:
 *
 * - mutable values (thanks to set-vec), that can be used to update a state;
 *
 * - various flavors of sets, with an API that let users (ie. ramen) knows the
 * last removed values (which will come handy to optimize some stateful
 * operator over sliding windows);
 *
 * So, like with the legacy code generator, states are kept in a record (field
 * names given by [field_name_of_state]);
 * actually, one record for the global states and one for each local (aka
 * group-wide) states. The exact type of this record is given by the actual
 * stateful functions used.
 * Each field is actually composed of a one dimensional vector so that values
 * can be changed with set-vec.
 *)

let pick_state r_env e state_lifespan =
  let state_var =
    match state_lifespan with
    | E.LocalState -> Lang.Group
    | E.GlobalState -> Lang.Global in
  try List.assoc (E.RecordValue state_var) r_env
  with Not_found ->
    Printf.sprintf2
      "Expression %a uses variable %s that is not available in the environment \
       (only %a)"
      (E.print false) e
      (Lang.string_of_variable state_var)
      print_r_env r_env |>
    failwith

(* Returns the field name in the state record for that expression: *)
let field_name_of_state e =
  "state_"^ string_of_int e.E.uniq_num

(* Returns the state of the expression: *)
let get_state state_rec e =
  let fname = field_name_of_state e in
  let open DE.Ops in
  get_vec (u8_of_int 0) (get_field fname state_rec)

let set_state state_rec e d =
  let fname = field_name_of_state e in
  let open DE.Ops in
  set_vec (u8_of_int 0) (get_field fname state_rec) d

let finalize_sf1 ~d_env aggr state =
  match aggr with
  | E.AggrMax | AggrMin | AggrFirst | AggrLast ->
      get_item 1 state
  | AggrSum ->
      state
      (* TODO: finalization for floats with Kahan sum *)
  | AggrAvg ->
      let count = get_item 0 state
      and ksum = get_item 1 state in
      div (DS.Kahan.finalize ~l:d_env ksum)
          (conv ~to_:(Mac Float) d_env count)
  | AggrAnd | AggrOr | AggrBitAnd | AggrBitOr | AggrBitXor | Group |
    Count ->
      (* The state is the final value: *)
      state
  | Distinct ->
      let b = get_item 1 state in
      get_vec (u8_of_int 0) b
  | _ ->
      todo "finalize_sf1"

(* Comparison function for heaps of pairs ordered by the second item: *)
let cmp ?(inv=false) item_t =
  DE.func2 item_t item_t (fun _l i1 i2 ->
    (* Should dessser have a compare function? *)
    if_
      ~cond:((if inv then gt else lt) (get_item 1 i1) (get_item 1 i2))
      ~then_:(i8_of_int ~-1)
      ~else_:(
        if_
          ~cond:((if inv then lt else gt) (get_item 1 i1) (get_item 1 i2))
          ~then_:(i8_of_int 1)
          ~else_:(i8_of_int 0)))

let lst_item_type e =
  match e.E.typ.DT.vtyp with
  | DT.Lst mn -> mn
  | _ ->
      !logger.error "Not a list?: %a" DT.print_value_type e.E.typ.DT.vtyp ;
      assert false (* Because of RamenTyping.ml *)

let past_item_t v_t =
  DT.(required (
    Tup [| v_t ; DT.{ vtyp = Mac Float ; nullable = false } |]))

let get_variable_binding ~r_env var =
  try List.assoc (E.RecordValue var) r_env
  with Not_found ->
      Printf.sprintf2
        "Cannot find a binding for %a in the environment (%a)"
        Lang.variable_print var
        print_r_env r_env |>
      failwith

(* This function returns the initial value of the state required to implement
 * the passed RaQL operator (which also provides its type): *)
let rec init_state ?depth ~r_env ~d_env e =
  let open DE.Ops in
  let depth = Option.map succ depth in
  let expr ~d_env =
    expression ?depth ~r_env ~d_env in
  match e.E.text with
  | Stateful (_, _, SF1 ((AggrMin | AggrMax | AggrFirst | AggrLast), _)) ->
      (* A bool to tell if there ever was a value, and the selected value *)
      make_tup [ bool false ; null e.typ.DT.vtyp ]
  | Stateful (_, _, SF1 (AggrSum, _)) ->
      u8_of_int 0 |>
      conv_maybe_nullable ~to_:e.E.typ d_env
      (* TODO: initialization for floats with Kahan sum *)
  | Stateful (_, _, SF1 (AggrAvg, _)) ->
      (* The state of the avg is composed of the count and the (Kahan) sum: *)
      make_tup [ u32_of_int 0 ; DS.Kahan.init ]
  | Stateful (_, _, SF1 (AggrAnd, _)) ->
      bool true
  | Stateful (_, _, SF1 (AggrOr, _)) ->
      bool false
  | Stateful (_, _, SF1 ((AggrBitAnd | AggrBitOr | AggrBitXor), _)) ->
      u8_of_int 0 |>
      conv_maybe_nullable ~to_:e.E.typ d_env
  | Stateful (_, _, SF1 (Group, _)) ->
      (* Groups are typed as lists not sets: *)
      let item_t =
        match e.E.typ.DT.vtyp with
        | DT.Lst mn -> mn
        | _ -> invalid_arg ("init_state: "^ E.to_string e) in
      empty_set item_t
  | Stateful (_, _, SF1 (Count, _)) ->
      u8_of_int 0 |>
      conv_maybe_nullable ~to_:e.E.typ d_env
  | Stateful (_, _, SF1 (Distinct, e)) ->
      (* Distinct result is a boolean telling if the last met value was already
       * present in the hash, so we also need to store that bool in the state
       * unfortunately. Since the hash_table is already mutable, let's also make
       * that boolean mutable: *)
      make_tup
        [ hash_table e.E.typ (u8_of_int 100) ;
          make_vec [ bool false ] ]
  | Stateful (_, _, SF2 (Lag, steps, e)) ->
      (* The state is just going to be a list of past values initialized with
       * NULLs (the value when we have so far received less than that number of
       * steps) and the index of the oldest value. *)
      let item_vtyp = e.E.typ.DT.vtyp in
      let steps = expr ~d_env steps in
      make_rec
        [ "past_values",
            (* We need one more item to remember the oldest value before it's
             * updated: *)
            (let len = add (u32_of_int 1) (to_u32 steps)
            and init = null item_vtyp in
            alloc_lst ~l:d_env ~len ~init) ;
          "oldest_index", ref_ (u32_of_int 0) ]
  | Stateful (_, _, SF2 (ExpSmooth, _, _)) ->
      null e.E.typ.DT.vtyp
  | Stateful (_, skip_nulls, SF2 (Sample, n, e)) ->
      let n = expr ~d_env n in
      let item_t =
        if skip_nulls then
          T.{ e.E.typ with nullable = false }
        else
          e.E.typ in
      sampling item_t n
  | Stateful (_, _, SF4s (Largest { inv ; _ }, _, _, _, by)) ->
      let v_t = lst_item_type e in
      let by_t =
        DT.required (
          if by = [] then
            (* [update_state] will then use the count field: *)
            Mac U32
          else
            (Tup (List.enum by /@ (fun e -> e.E.typ) |> Array.of_enum))) in
      let item_t = DT.tuple [| v_t ; by_t |] in
      let cmp = cmp ~inv item_t in
      make_rec
        [ (* Store each values and its weight in a heap: *)
          "values", heap cmp ;
          (* Count insertions, to serve as a default order: *)
          "count", ref_ (u32_of_int 0) ]
  | Stateful (_, _, Past { max_age ; sample_size ; _ }) ->
      if sample_size <> None then
        todo "PAST operator with integrated sampling" ;
      let v_t = lst_item_type e in
      let item_t = past_item_t v_t in
      let cmp = cmp (DT.Value item_t) in
      make_rec
        [ "values", heap cmp ;
          "max_age", to_float (expr ~d_env max_age) ;
          (* If tumbled is true, finalizer should then empty the values: *)
          "tumbled", ref_ (DE.Ops.null DT.(Set (Heap, item_t))) ;
          (* TODO: sampling *) ]
  | Stateful (_, _, Top { size ; max_size ; sigmas ; what ; _ }) ->
      (* Dessser TOP set uses a special [insert_weighted] operator to insert
       * values with a weight. It has no notion of time and decay so decay will
       * be implemented when updating the state by inflating the weights with
       * time. It is therefore necessary to store the starting time in the
       * state in addition to the top itself. *)
      let size_t = size.E.typ.DT.vtyp in
      let item_t = what.E.typ in
      let size = expr ~d_env size in
      let max_size =
        match max_size with
        | Some max_size ->
            expr ~d_env max_size
        | None ->
            let ten = conv ~to_:size_t d_env (u8_of_int 10) in
            mul ten size in
      let sigmas = expr ~d_env sigmas in
      make_rec
        [ "starting_time", ref_ (null T.(Mac Float)) ;
          "top", top item_t (to_u32 size) (to_u32 max_size) sigmas ]
  | _ ->
      (* TODO *)
      todo ("init_state of "^ E.to_string ~max_depth:1 e)

and  get_field_binding ~r_env ~d_env var field =
  let k = E.RecordField (var, field) in
  try List.assoc k r_env with
  | Not_found ->
      (* If not, that means this field has not been overridden but we may
       * still find the record it's from and pretend we have a Get from
       * the Variable instead: *)
      let binding = get_variable_binding ~r_env var in
      apply_1 d_env binding (fun _d_env binding ->
        get_field (field :> string) binding)

(* Returns the type of the state record needed to store the states of all the
 * given stateful expressions: *)
and state_rec_type_of_expressions ~r_env ~d_env es =
  let mns =
    List.map (fun e ->
      let d = init_state ~r_env ~d_env e in
      !logger.debug "init state of %a: %a"
        (E.print false) e
        (DE.print ?max_depth:None) d ;
      let mn = mn_of_t (DE.type_of d_env d) in
      field_name_of_state e,
      (* The value is a 1 dimensional (mutable) vector *)
      DT.(required (Vec (1, mn)))
    ) es |>
    Array.of_list in
  if mns = [||] then DT.(required Unit)
                else DT.(required (Rec mns))

(* Implement an SF1 aggregate function, assuming skip_nulls is handled by the
 * caller (necessary since the item and state are already evaluated).
 * NULL item will propagate to the state.
 * Used for normal state updates as well as aggregation over lists: *)
and update_state_sf1 ~d_env ~convert_in aggr item state =
  let open DE.Ops in
  (* if [d] is nullable and null, then returns it, else apply [f] to (forced,
   * if nullable) value of [d] and return not_null (if nullable) of that
   * instead. This propagates [d]'s nullability to the result of the
   * aggregation. *)
  let null_map ~d_env d f =
    let_ ~name:"null_map" ~l:d_env d (fun d_env d ->
      match DE.type_of d_env d with
      | DT.Value { nullable = true ; _ } ->
          if_
            ~cond:(is_null d)
            ~then_:d
            ~else_:(ensure_nullable ~d_env (f d_env (force d)))
      | _ ->
          f d_env d) in
  match aggr with
  | E.AggrMax | AggrMin | AggrFirst | AggrLast ->
      let d_op =
        match aggr, mn_of_t (DE.type_of d_env item) with
        (* As a special case, RaQL allows boolean arguments to min/max: *)
        | AggrMin, DT.{ vtyp = Mac Bool ; _ } ->
            and_
        | AggrMax, DT.{ vtyp = Mac Bool ; _ } ->
            or_
        | AggrMin, _ ->
            min_
        | AggrMax, _ ->
            max_
        | AggrFirst, _ ->
            (fun s _d -> s)
        | _ ->
            assert (aggr = AggrLast) ;
            (fun _s d -> d) in
      let new_state_val =
        (* In any case, if we never got a value then we select this one and
         * call it a day: *)
        if_
          ~cond:(not_ (get_item 0 state))
          ~then_:(ensure_nullable ~d_env item)
          ~else_:(
            apply_2 ~convert_in d_env (get_item 1 state) item
                    (fun _d_env -> d_op)) in
      make_tup [ bool true ; new_state_val ]
  | AggrSum ->
      (* Typing can decide the state and/or item are nullable.
       * In any case, nulls must propagate: *)
      apply_2 ~convert_in d_env state item (fun _d_env -> add)
      (* TODO: update for float with Kahan sum *)
  | AggrAvg ->
      let count = get_item 0 state
      and ksum = get_item 1 state in
      null_map ~d_env item (fun d_env d ->
        make_tup [ add count (u32_of_int 1) ;
                   DS.Kahan.add ~l:d_env ksum d])
  | AggrAnd ->
      apply_2 d_env state item (fun _d_env -> and_)
  | AggrOr ->
      apply_2 d_env state item (fun _d_env -> or_)
  | AggrBitAnd ->
      apply_2 ~convert_in d_env state item (fun _d_env -> log_and)
  | AggrBitOr ->
      apply_2 ~convert_in d_env state item (fun _d_env -> log_or)
  | AggrBitXor ->
      apply_2 ~convert_in d_env state item (fun _d_env -> log_xor)
  | Group ->
      insert state item
  | Count ->
      let one d_env =
        conv ~to_:convert_in d_env (u8_of_int 1) in
      (match DE.type_of d_env item with
      | DT.(Value { vtyp = Mac Bool ; _ }) ->
          (* Count how many are true *)
          apply_2 d_env state item (fun d_env state item ->
            if_
              ~cond:item
              ~then_:(add state (one d_env))
              ~else_:state)
      | _ ->
          (* Just count.
           * In previous versions it used to be that count would never be
           * nullable in this case, even when counting nullable items and not
           * skipping nulls, since we can still count unknown values.
           * But having special cases as this in NULL propagation makes this
           * code harder and is also harder for the user who would try to
           * memorise the rules. Better keep it simple and let
           *   COUNT KEEP NULLS NULL
           * be NULL. It is simple enough to write instead:
           *   COUNT (X IS NOT NULL)
           * FIXME: Update typing accordingly. *)
          apply_1 d_env state (fun d_env state -> add state (one d_env)))
  | Distinct ->
      let h = get_item 0 state
      and b = get_item 1 state in
      if_
        ~cond:(member item h)
        ~then_:(set_vec (u8_of_int 0) b (bool false))
        ~else_:(
          seq [
            insert h item ;
            set_vec (u8_of_int 0) b (bool true) ])
  | _ ->
      todo "update_state_sf1"

(* Implement an SF1 aggregate function, assuming skip_nulls is handled by the
 * caller (necessary since the item and state are already evaluated).
 * NULL item will propagate to the state.
 * Used for normal state updates as well as aggregation over lists: *)
and update_state_sf2 ~d_env ~convert_in aggr item1 item2 state =
  ignore convert_in ;
  let open DE.Ops in
  match aggr with
  | E.Lag ->
      let past_vals = get_field "past_values" state
      and oldest_index = get_field "oldest_index" state in
      let item2 =
        if DT.is_nullable (DE.type_of d_env item2) then item2
                                                   else not_null item2 in
      seq [
        set_vec (get_ref oldest_index) past_vals item2 ;
        let next_oldest = add (get_ref oldest_index) (u32_of_int 1) in
        let_ ~name:"next_oldest" ~l:d_env next_oldest (fun _d_env next_oldest ->
          let next_oldest =
            if_
              (* [gt] because we had item1+1 items in past_vals: *)
              ~cond:(gt next_oldest (to_u32 item1))
              ~then_:(u32_of_int 0)
              ~else_:next_oldest in
          set_ref oldest_index next_oldest) ]
  | ExpSmooth ->
      if_
        ~cond:(is_null state)
        ~then_:item2
        ~else_:(
          add (mul item2 item1)
              (mul (force state)
                   (sub (float 1.) (to_float item1)))) |>
      not_null
  | Sample ->
      insert state item2
  | _ ->
      todo "update_state_sf2"

and update_state_sf4s ~d_env ~convert_in aggr item1 item2 item3 item4s state =
  ignore convert_in ;
  ignore item2 ;
  match aggr with
  | E.Largest _ ->
      let max_len = to_u32 item1
      and e = item3
      and by = item4s in
      let_ ~name:"values" ~l:d_env (get_field "values" state) (fun d_env values ->
        let_ ~name:"count" ~l:d_env (get_field "count" state) (fun d_env count ->
          let by =
            (* Special updater that use the internal count when no `by` expressions
             * are present: *)
            if by = [] then [ get_ref count ] else by in
          let by = make_tup by in
          let heap_item = make_tup [ e ; by ] in
          seq [
            set_ref count (add (get_ref count) (u32_of_int 1)) ;
            insert values heap_item ;
            let_ ~name:"heap_len" ~l:d_env (cardinality values) (fun _d_env heap_len ->
              if_
                ~cond:(eq heap_len max_len)
                ~then_:(del_min values (u32_of_int 1))
                ~else_:(assert_ (lt heap_len max_len))) ]))
  | _ ->
      todo "update_state_sf4s"

and update_state_past ~d_env ~convert_in tumbling what time state v_t =
  ignore convert_in ;
  let open DE.Ops in
  let values = get_field "values" state
  and max_age = get_field "max_age" state
  and tumbled = get_field "tumbled" state in
  let item_t =
    DT.required (Tup [| v_t ; DT.{ vtyp = Mac Float ; nullable = false } |]) in
  let expell_the_olds =
    if_
      ~cond:(gt (cardinality values) (u32_of_int 0))
      ~then_:(
        let min_time = get_item 1 (get_min values) in
        if tumbling then (
          let_ ~name:"min_time" ~l:d_env min_time (fun _d_env min_time ->
            (* Tumbling window: empty (and save) the whole data set when time
             * is due *)
            set_ref tumbled (
              if_
                ~cond:(eq (to_i32 (div time max_age))
                          (to_i32 (div min_time max_age)))
                ~then_:(null DT.(Set (Heap, item_t)))
                ~else_:(not_null values)))
        ) else (
          (* Sliding window: remove any value older than max_age *)
          loop_while
            ~cond:(lt (sub time min_time) max_age)
            ~body:(del_min values (u32_of_int 1))
            ~init:nop
        ))
      ~else_:nop |>
    comment "Expelling old values" in
  seq [
    expell_the_olds ;
    insert values (make_tup [ what ; time ]) ]

and update_state_top ~d_env ~convert_in what by decay time state =
  ignore convert_in ;
  (* Those two can be any numeric: *)
  let time = to_float time
  and by = to_float by in
  let open DE.Ops in
  let starting_time = get_field "starting_time" state
  and top = get_field "top" state in
  let inflation =
    let_ ~name:"starting_time" ~l:d_env (get_ref starting_time) (fun d_env t0_opt ->
      if_
        ~cond:(is_null t0_opt)
        ~then_:(
          seq [
            set_ref starting_time (not_null time) ;
            float 1. ])
        ~else_:(
          let infl = exp (mul decay (sub time (force t0_opt))) in
          let_ ~name:"top_infl" ~l:d_env infl (fun _d_env infl ->
            let max_infl = float 1e6 in
            if_
              ~cond:(lt infl max_infl)
              ~then_:infl
              ~else_:(
                seq [
                  scale_weights top (force (div (float 1.) infl)) ;
                  set_ref starting_time (not_null time) ;
                  float 1. ])))) in
  let_ ~name:"top_inflation" ~l:d_env inflation (fun d_env inflation ->
    let weight = mul by inflation in
    let_ ~name:"weight" ~l:d_env weight (fun _d_env weight ->
      insert_weighted top weight what))

(* Environments:
 * - [d_env] is the environment used by dessser, ie. a stack of
 *   expression x type (expression being for instance [(identifier n)] or
 *   [(param n m)]. This is used by dessser to do type-checking.
 *   The environment must contain the required external identifiers set by
 *   the [init] function.
 * - [r_env] is the stack of currently reachable "raql thing", such
 *   as expression state, a record (in other words an E.binding_key), bound
 *   to a dessser expression (typically an identifier or a param). *)
and expression ?(depth=0) ~r_env ~d_env e =
  !logger.debug "%sCompiling into DIL: %a"
    (indent_of depth)
    (E.print true) e ;
  assert (E.is_typed e) ;
  let apply_1 = apply_1 ~depth
  and apply_2 = apply_2 ~depth in
  let depth = depth + 1 in
  let expr ~d_env =
    expression ~depth ~r_env ~d_env in
  let bad_type () =
    Printf.sprintf2 "Invalid type %a for expression %a"
      DT.print_maybe_nullable e.E.typ
      (E.print false) e |>
    failwith in
  let convert_in = e.E.typ.DT.vtyp in
  let conv = conv ~depth
  and conv_maybe_nullable = conv_maybe_nullable ~depth in
  let conv_from d_env d =
    conv ~to_:e.E.typ.DT.vtyp d_env d in
  let conv_maybe_nullable_from d_env d =
    conv_maybe_nullable ~to_:e.E.typ d_env d in
  (* In any case we want the output to be converted to the expected type: *)
  conv_maybe_nullable_from d_env (
    match e.E.text with
    | Const v ->
        constant e.E.typ v
    | Tuple es ->
        (match e.E.typ.DT.vtyp with
        | DT.Tup mns ->
            if Array.length mns <> List.length es then bad_type () ;
            (* Better convert items before constructing the tuple: *)
            List.mapi (fun i e ->
              conv_maybe_nullable ~to_:mns.(i) d_env (expr ~d_env e)
            ) es |>
            make_tup
        | _ ->
            bad_type ())
    | Record nes ->
        (match e.E.typ.DT.vtyp with
        | DT.Rec mns ->
            if Array.length mns <> List.length nes then bad_type () ;
            List.mapi (fun i (n, e) ->
              (n : N.field :> string),
              conv_maybe_nullable ~to_:(snd mns.(i)) d_env (expr ~d_env e)
            ) nes |>
            make_rec
        | _ ->
            bad_type ())
    | Vector es ->
        (match e.E.typ.DT.vtyp with
        | DT.Vec (dim, mn) ->
            if dim <> List.length es then bad_type () ;
            List.map (fun e ->
              conv_maybe_nullable ~to_:mn d_env (expr ~d_env e)
            ) es |>
            make_vec
        | _ ->
            bad_type ())
    | Variable v ->
        (* We probably want to replace this with a DIL identifier with a
         * well known name: *)
        identifier (Lang.string_of_variable v)
    | Binding (E.RecordField (var, field)) ->
        (* Try first to see if there is this specific binding in the
         * environment. *)
        get_field_binding ~r_env ~d_env var field
    | Binding k ->
        (* A reference to the raql environment. Look for the dessser expression it
         * translates to. *)
        (try List.assoc k r_env with
        | Not_found ->
            Printf.sprintf2
              "Cannot find a binding for %a in the environment (%a)"
              E.print_binding_key k
              print_r_env r_env |>
            failwith)
    | Case (alts, else_) ->
        let rec alt_loop = function
          | [] ->
              (match else_ with
              | Some e -> conv_maybe_nullable_from d_env (expr ~d_env e)
              | None -> null e.E.typ.DT.vtyp)
          | E.{ case_cond = cond ; case_cons = cons } :: alts' ->
              let do_cond d_env cond =
                if_ ~cond
                    ~then_:(conv_maybe_nullable ~to_:e.E.typ d_env (expr ~d_env cons))
                    ~else_:(alt_loop alts') in
              if cond.E.typ.DT.nullable then
                let_ ~name:"nullable_cond_" ~l:d_env (expr ~d_env cond)
                  (fun d_env cond ->
                    if_ ~cond:(is_null cond)
                        ~then_:(null e.E.typ.DT.vtyp)
                        ~else_:(do_cond d_env (force cond)))
              else
                do_cond d_env (expr ~d_env cond) in
        alt_loop alts
    | Stateless (SL0 Now) ->
        conv_from d_env now
    | Stateless (SL0 Random) ->
        random_float
    | Stateless (SL0 Pi) ->
        float Float.pi
    | Stateless (SL0 EventStart) ->
        (* No support for event-time expressions, just convert into the start/stop
         * fields: *)
        get_field_binding ~r_env ~d_env Out (N.field "start")
    | Stateless (SL0 EventStop) ->
        get_field_binding ~r_env ~d_env Out (N.field "stop")
    | Stateless (SL1 (Age, e1)) ->
        apply_1 ~convert_in d_env (expr ~d_env e1) (fun _l d -> sub now d)
    | Stateless (SL1 (Cast _, e1)) ->
        (* Type checking already set the output type of that Raql expression to the
         * target type, and the result will be converted into this type in any
         * case. *)
        expr ~d_env e1
    | Stateless (SL1 (Force, e1)) ->
        force ~what:"explicit Force" (expr ~d_env e1)
    | Stateless (SL1 (Peek (vtyp, endianness), e1)) when E.is_a_string e1 ->
        (* vtyp is some integer. *)
        apply_1 d_env (expr ~d_env e1) (fun _d_env d1 ->
          let ptr = data_ptr_of_string d1 in
          let offs = size 0 in
          match vtyp with
          | DT.Mac U128 -> u128_of_oword (peek_oword endianness ptr offs)
          | DT.Mac U64 -> u64_of_qword (peek_qword endianness ptr offs)
          | DT.Mac U32 -> u32_of_dword (peek_dword endianness ptr offs)
          | DT.Mac U16 -> u16_of_word (peek_word endianness ptr offs)
          | DT.Mac U8 -> u8_of_byte (peek_byte ptr offs)
          | DT.Mac I128 -> to_i128 (u128_of_oword (peek_oword endianness ptr offs))
          | DT.Mac I64 -> to_i64 (u64_of_qword (peek_qword endianness ptr offs))
          | DT.Mac I32 -> to_i32 (u32_of_dword (peek_dword endianness ptr offs))
          | DT.Mac I16 -> to_i16 (u16_of_word (peek_word endianness ptr offs))
          | DT.Mac I8 -> to_i8 (peek_byte ptr offs)
          (* Other widths TODO. We might not have enough bytes to read as
           * many bytes than the larger integer type. *)
          | _ ->
              Printf.sprintf2 "Peek %a" DT.print_value_type vtyp |>
              todo)
    | Stateless (SL1 (Length, e1)) ->
        apply_1 d_env (expr ~d_env e1) (fun _d_env d1 ->
          match e1.E.typ.DT.vtyp with
          | DT.Mac String -> string_length d1
          | DT.Lst _ -> cardinality d1
          | _ -> bad_type ()
        )
    | Stateless (SL1 (Lower, e1)) ->
        apply_1 d_env (expr ~d_env e1) (fun _l d -> lower d)
    | Stateless (SL1 (Upper, e1)) ->
        apply_1 d_env (expr ~d_env e1) (fun _l d -> upper d)
    | Stateless (SL1 (UuidOfU128, e1)) ->
        apply_1 d_env (expr ~d_env e1) (fun _l d ->
          apply (ext_identifier "CodeGenLib.uuid_of_u128") [ d ])
    | Stateless (SL1 (Not, e1)) ->
        apply_1 d_env (expr ~d_env e1) (fun _l d -> not_ d)
    | Stateless (SL1 (Abs, e1)) ->
        apply_1 d_env (expr ~d_env e1) (fun _l d -> abs d)
    | Stateless (SL1 (Minus, e1)) ->
        apply_1 d_env (expr ~d_env e1) (fun _l d -> neg d)
    | Stateless (SL1 (Defined, e1)) ->
        not_ (is_null (expr ~d_env e1))
    | Stateless (SL1 (Exp, e1)) ->
        apply_1 d_env (expr ~d_env e1) (fun _l d -> exp d)
    | Stateless (SL1 (Log, e1)) ->
        apply_1 d_env (expr ~d_env e1) (fun _l d -> log_ d)
    | Stateless (SL1 (Log10, e1)) ->
        apply_1 d_env (expr ~d_env e1) (fun _l d -> log10_ d)
    | Stateless (SL1 (Sqrt, e1)) ->
        apply_1 d_env (expr ~d_env e1) (fun _l d -> sqrt_ d)
    | Stateless (SL1 (Ceil, e1)) ->
        apply_1 d_env (expr ~d_env e1) (fun _l d -> ceil_ d)
    | Stateless (SL1 (Floor, e1)) ->
        apply_1 d_env (expr ~d_env e1) (fun _l d -> floor_ d)
    | Stateless (SL1 (Round, e1)) ->
        apply_1 d_env (expr ~d_env e1) (fun _l d -> round d)
    | Stateless (SL1 (Cos, e1)) ->
        apply_1 d_env (expr ~d_env e1) (fun _l d -> cos_ d)
    | Stateless (SL1 (Sin, e1)) ->
        apply_1 d_env (expr ~d_env e1) (fun _l d -> sin_ d)
    | Stateless (SL1 (Tan, e1)) ->
        apply_1 d_env (expr ~d_env e1) (fun _l d -> tan_ d)
    | Stateless (SL1 (ACos, e1)) ->
        apply_1 d_env (expr ~d_env e1) (fun _l d -> acos_ d)
    | Stateless (SL1 (ASin, e1)) ->
        apply_1 d_env (expr ~d_env e1) (fun _l d -> asin_ d)
    | Stateless (SL1 (ATan, e1)) ->
        apply_1 d_env (expr ~d_env e1) (fun _l d -> atan_ d)
    | Stateless (SL1 (CosH, e1)) ->
        apply_1 d_env (expr ~d_env e1) (fun _l d -> cosh_ d)
    | Stateless (SL1 (SinH, e1)) ->
        apply_1 d_env (expr ~d_env e1) (fun _l d -> sinh_ d)
    | Stateless (SL1 (TanH, e1)) ->
        apply_1 d_env (expr ~d_env e1) (fun _l d -> tanh_ d)
    | Stateless (SL1 (Hash, e1)) ->
        apply_1 d_env (expr ~d_env e1) (fun _l d -> hash d)
    | Stateless (SL1 (Chr, e1)) ->
        apply_1 d_env (expr ~d_env e1) (fun d_env d1 ->
          char_of_u8 (conv ~to_:DT.(Mac U8) d_env d1)
        )
    | Stateless (SL1 (Basename, e1)) ->
        apply_1 d_env (expr ~d_env e1) (fun d_env d1 ->
          let_ ~name:"str_" ~l:d_env d1 (fun d_env str ->
            let pos = find_substring (bool false) (string "/") str in
            let_ ~name:"pos_" ~l:d_env pos (fun _d_env pos ->
              if_
                ~cond:(is_null pos)
                ~then_:str
                ~else_:(split_at (add (u24_of_int 1) (force pos)) str |>
                        get_item 1)))
        )
    | Stateless (SL1s ((Max | Min as op), es)) ->
        let d_op = match op with Max -> max | _ -> min in
        (match es with
        | [] ->
            assert false
        | [ e1 ] ->
            apply_1 d_env (expr ~d_env e1) (fun d_env d -> conv_from d_env d)
        | e1 :: es' ->
            apply_1 d_env (expr ~d_env e1) (fun d_env d1 ->
              let rest = { e with text = Stateless (SL1s (op, es')) } in
              apply_1 d_env (expr ~d_env rest) (fun d_env d2 ->
                d_op (conv_from d_env d1) d2)))
    | Stateless (SL1s (Print, es)) ->
        let to_string d_env d =
          let nullable =
            match DE.type_of d_env d with
            | DT.Value { nullable ; _ } -> nullable
            | _ -> false in
          if nullable then
            if_
              ~cond:(is_null d)
              ~then_:(string "<NULL>")
              ~else_:(
                conv ~to_:DT.(Mac String) d_env (force d))
          else
            conv ~to_:DT.(Mac String) d_env d in
        (match List.rev es with
        | e1 :: es ->
            let_ ~name:"sep" ~l:d_env (string "; ") (fun d_env sep ->
              let_ ~name:"last_printed" ~l:d_env (expr ~d_env e1) (fun d_env d1 ->
                let dumps =
                  List.fold_left (fun lst e ->
                    let lst =
                      if lst = [] then lst else dump sep :: lst in
                    dump (to_string d_env (expr ~d_env e)) :: lst
                  ) [] es in
                seq (
                  [ dump (string "PRINT: [ ") ] @
                  dumps @
                  (if dumps = [] then [] else [ dump sep ]) @
                  [ dump (to_string d_env d1) ;
                    dump (string " ]\n") ;
                    d1 ])))
        | [] ->
            invalid_arg "RaQL2DIL.expression: empty PRINT")
    | Stateless (SL1s (Coalesce, es)) ->
        let es =
          List.map (fun e1 ->
            (* Convert to the result's vtyp: *)
            let to_ = DT.{ e.E.typ with nullable = e1.E.typ.DT.nullable } in
            conv_maybe_nullable ~to_ d_env (expr ~d_env e1)
          ) es in
        DessserStdLib.coalesce d_env es
    | Stateless (SL2 (Add, e1, e2)) ->
        apply_2 ~convert_in d_env (expr ~d_env e1) (expr ~d_env e2) (fun _d_env -> add)
    | Stateless (SL2 (Sub, e1, e2)) ->
        apply_2 ~convert_in d_env (expr ~d_env e1) (expr ~d_env e2) (fun _d_env -> sub)
    | Stateless (SL2 (Mul, e1, e2)) ->
        apply_2 ~convert_in d_env (expr ~d_env e1) (expr ~d_env e2) (fun _d_env -> mul)
    | Stateless (SL2 (Div, e1, e2)) ->
        apply_2 ~convert_in d_env (expr ~d_env e1) (expr ~d_env e2) (fun _d_env -> div)
    | Stateless (SL2 (IDiv, e1, e2)) ->
        (* When the result is a float we need to floor it *)
        (match e.E.typ with
        | DT.{ vtyp = Mac Float ; _ } ->
            apply_2 ~convert_in d_env (expr ~d_env e1) (expr ~d_env e2) (fun d_env d1 d2 ->
              apply_1 d_env (div d1 d2) (fun _d_env d -> floor_ d))
        | _ ->
            apply_2 ~convert_in d_env (expr ~d_env e1) (expr ~d_env e2) (fun _d_env -> div))
    | Stateless (SL2 (Mod, e1, e2)) ->
        apply_2 ~convert_in d_env (expr ~d_env e1) (expr ~d_env e2) (fun _d_env -> rem)
    | Stateless (SL2 (Pow, e1, e2)) ->
        apply_2 ~convert_in d_env (expr ~d_env e1) (expr ~d_env e2) (fun _d_env -> pow)
    | Stateless (SL2 (And, e1, e2)) ->
        apply_2 d_env (expr ~d_env e1) (expr ~d_env e2) (fun _d_env -> and_)
    | Stateless (SL2 (Or, e1, e2)) ->
        apply_2 d_env (expr ~d_env e1) (expr ~d_env e2) (fun _d_env -> or_)
    | Stateless (SL2 (Ge, e1, e2)) ->
        apply_2 ~enlarge_in:true d_env (expr ~d_env e1) (expr ~d_env e2) (fun _d_env -> ge)
    | Stateless (SL2 (Gt, e1, e2)) ->
        apply_2 ~enlarge_in:true d_env (expr ~d_env e1) (expr ~d_env e2) (fun _d_env -> gt)
    | Stateless (SL2 (Eq, e1, e2)) ->
        apply_2 ~enlarge_in:true d_env (expr ~d_env e1) (expr ~d_env e2) (fun _d_env -> eq)
    | Stateless (SL2 (Concat, e1, e2)) ->
        apply_2 d_env (expr ~d_env e1) (expr ~d_env e2) (fun _d_env d1 d2 ->
          join (string "") (make_vec [ d1 ; d2 ]))
    | Stateless (SL2 (StartsWith, e1, e2)) ->
        apply_2 d_env (expr ~d_env e1) (expr ~d_env e2) (fun _d_env -> starts_with)
    | Stateless (SL2 (EndsWith, e1, e2)) ->
        apply_2 d_env (expr ~d_env e1) (expr ~d_env e2) (fun _d_env -> ends_with)
    | Stateless (SL2 (BitAnd, e1, e2)) ->
        apply_2 ~enlarge_in:true d_env (expr ~d_env e1) (expr ~d_env e2) (fun _d_env -> log_and)
    | Stateless (SL2 (BitOr, e1, e2)) ->
        apply_2 ~enlarge_in:true d_env (expr ~d_env e1) (expr ~d_env e2) (fun _d_env -> log_or)
    | Stateless (SL2 (BitXor, e1, e2)) ->
        apply_2 ~enlarge_in:true d_env (expr ~d_env e1) (expr ~d_env e2) (fun _d_env -> log_xor)
    | Stateless (SL2 (BitShift, e1, { text = Stateless (SL1 (Minus, e2)) ; _ })) ->
        apply_2 d_env (expr ~d_env e1) (expr ~d_env e2) (fun _d_env d1 d2 -> right_shift d1 (to_u8 d2))
    | Stateless (SL2 (BitShift, e1, e2)) ->
        apply_2 d_env (expr ~d_env e1) (expr ~d_env e2) (fun _d_env d1 d2 -> left_shift d1 (to_u8 d2))
    | Stateless (SL2 (Get, { text = Const (VString n) ; _ }, e2)) ->
        apply_1 d_env (expr ~d_env e2) (fun _l d -> get_field n d)
    (* Constant get from a vector: the nullability merely propagates, and the
     * program will crash if the constant index is outside the constant vector
     * counds: *)
    | Stateless (SL2 (Get, ({ text = Const n ; _ } as e1),
                           ({ typ = DT.{ vtyp = Vec _ ; _ } ; _ } as e2)))
      when E.is_integer n ->
        apply_2 d_env (expr ~d_env e1) (expr ~d_env e2) (fun _l -> get_vec)
    (* In all other cases the result is always nullable, in case the index goes
     * beyond the bounds: *)
    | Stateless (SL2 (Get, e1, e2)) ->
        apply_2 d_env (expr ~d_env e1) (expr ~d_env e2) (fun d_env d1 d2 ->
          let_ ~name:"getted" ~l:d_env d2 (fun d_env d2 ->
            let zero = conv ~to_:e1.E.typ.DT.vtyp d_env (i8_of_int 0) in
            if_
              ~cond:(and_ (ge d1 zero) (lt d1 (cardinality d2)))
              ~then_:(conv_maybe_nullable_from d_env (get_vec d1 d2))
              ~else_:(null e.E.typ.DT.vtyp)))
    | Stateless (SL2 (Index, str, chr)) ->
        apply_2 d_env (expr ~d_env str) (expr ~d_env chr) (fun d_env str chr ->
          match find_substring true_ (string_of_char chr) str with
          | E0 (Null _) ->
              i32_of_int ~-1
          | res ->
              let_ ~name:"index_" ~l:d_env res (fun d_env res ->
                if_
                  ~cond:(is_null res)
                  ~then_:(i32_of_int ~-1)
                  ~else_:(conv ~to_:DT.(Mac I32) d_env (force res))))
    | Stateless (SL2 (Percentile, e1, percs)) ->
        apply_2 d_env (expr ~d_env e1) (expr ~d_env percs) (fun d_env d1 percs ->
          match e.E.typ.DT.vtyp with
          | Vec _ ->
              DS.percentiles ~l:d_env d1 percs
          | _ ->
              DS.percentiles ~l:d_env d1 (make_vec [ percs ]) |>
              get_vec (u8_of_int 0))
    (*
     * Stateful functions:
     * When the argument is a list then those functions are actually stateless:
     *)
    (* FIXME: do not store a state for those in any state vector *)
    | Stateful (_, skip_nulls, SF1 (aggr, list))
      when E.is_a_list list ->
        let state = init_state ~r_env ~d_env e in
        let state_t = DE.type_of d_env state in
        let list_nullable, list_item_t =
          match list.E.typ with
          | DT.{ nullable ; vtyp = (Vec (_, t) | Lst t | Set (_, t)) } ->
              nullable, t
          | _ ->
              assert false (* Because 0f `E.is_a_list list` *) in
        let convert_in = e.E.typ.DT.vtyp in
        let do_fold list =
          fold
            ~init:state
            ~body:(
              DE.func2 ~l:d_env state_t (Value list_item_t) (fun d_env state item ->
                let update_state ~d_env item =
                  let new_state =
                    update_state_sf1 ~d_env ~convert_in aggr item state in
                  (* If update_state_sf1 returns void, pass the given state that's
                   * been mutated: *)
                  if DT.eq DT.void (DE.type_of d_env new_state) then state
                  else new_state in
                if skip_nulls && DT.is_nullable (DE.type_of d_env item) then
                  if_
                    ~cond:(is_null item)
                    ~then_:state
                    ~else_:(
                      update_state ~d_env (force item))
                else
                  update_state ~d_env item))
            ~list in
        let list = expr ~d_env list in
        let state =
          if list_nullable then
            if_
              ~cond:(is_null list)
              ~then_:(null (mn_of_t state_t).DT.vtyp)
              ~else_:(do_fold (force list))
          else
            do_fold list in
        (* Finalize the state: *)
        finalize_sf1 ~d_env aggr state
    | Stateful (state_lifespan, _, SF1 (aggr, _)) ->
        let state_rec = pick_state r_env e state_lifespan in
        let state = get_state state_rec e in
        finalize_sf1 ~d_env aggr state
    | Stateful (state_lifespan, _, SF2 (Lag, _, _)) ->
        let state_rec = pick_state r_env e state_lifespan in
        let state = get_state state_rec e in
        let past_vals = get_field "past_values" state
        and oldest_index = get_field "oldest_index" state in
        get_vec (get_ref oldest_index) past_vals
    | Stateful (state_lifespan, _, SF2 (ExpSmooth, _, _)) ->
        let state_rec = pick_state r_env e state_lifespan in
        let state = get_state state_rec e in
        force ~what:"finalize ExpSmooth" state
    | Stateful (state_lifespan, _, SF2 (Sample, _, _)) ->
        let state_rec = pick_state r_env e state_lifespan in
        let state = get_state state_rec e in
        (* If the result is nullable then empty-set is Null. Otherwise
         * an empty set is not possible according to type-checking. *)
        let_ ~name:"sample_set" ~l:d_env state (fun d_env set ->
          if e.E.typ.DT.nullable then
            if_
              ~cond:(eq (cardinality set) (u32_of_int 0))
              ~then_:(null (mn_of_t (DE.type_of d_env set)).DT.vtyp)
              ~else_:(not_null set)
          else
            set)
    | Stateful (state_lifespan, _,
                SF4s (Largest { up_to ; _ }, max_len, but, _, _)) ->
        let state_rec = pick_state r_env e state_lifespan in
        let state = get_state state_rec e in
        let values = get_field "values" state in
        let_ ~name:"values" ~l:d_env values (fun d_env values ->
          let but = to_u32 (expr ~d_env but) in
          let_ ~name:"but" ~l:d_env but (fun d_env but ->
            let heap_len = cardinality values in
            let_ ~name:"heap_len" ~l:d_env heap_len (fun d_env heap_len ->
              let max_len = to_u32 (expr ~d_env max_len) in
              let_ ~name:"max_len" ~l:d_env max_len (fun d_env max_len ->
                let item_t =
                  (* TODO: get_min for sets *)
                  match DE.type_of d_env values with
                  | DT.Value { vtyp = Set (_, mn) ; _ } -> mn
                  | _ -> assert false (* Because of [type_check]  *) in
                let proj =
                  DE.func1 ~l:d_env (DT.Value item_t) (fun _d_env item ->
                    get_item 0 item) in
                let res =
                  not_null (chop_end (map_ (list_of_set values) proj) but) in
                let cond = lt heap_len max_len in
                let cond =
                  if up_to then and_ cond (le heap_len but)
                           else cond in
                if_ ~cond
                  ~then_:(null e.E.typ.DT.vtyp)
                  ~else_:res))))
    | Stateful (state_lifespan, _, Past { tumbling ; _ }) ->
        let state_rec = pick_state r_env e state_lifespan in
        let state = get_state state_rec e in
        let values = get_field "values" state in
        let v_t = lst_item_type e in
        let item_t = past_item_t v_t in
        let_ ~name:"values" ~l:d_env values (fun d_env values ->
          let proj =
            DE.func1 ~l:d_env (DT.Value item_t) (fun d_env heap_item ->
              (conv_maybe_nullable ~to_:v_t d_env (get_item 0 heap_item))) in
          (if tumbling then
            let tumbled = get_field "tumbled" state in
            let_ ~name:"tumbled" ~l:d_env tumbled (fun _d_env tumbled ->
              if_
                ~cond:(is_null tumbled)
                ~then_:(null e.E.typ.DT.vtyp)
                ~else_:(not_null (list_of_set (map_ tumbled proj))))
          else
            not_null (list_of_set (map_ values proj))))
    | Stateful (state_lifespan, _, Top { what ; output ; _ }) ->
        let state_rec = pick_state r_env e state_lifespan in
        let state = get_state state_rec e in
        let top = get_field "top" state in
        (match output with
        | Rank ->
            todo "Top RANK"
        | Membership ->
            let what = expr ~d_env what in
            member what top
        | List ->
            list_of_set top)
    | _ ->
        Printf.sprintf2 "RaQL2DIL.expression for %a"
          (E.print false) e |>
        todo
  )

(*$= expression & ~printer:identity
  "(u8 1)" (expression ~r_env:[] ~d_env:[] (E.of_u8 1) |> IO.to_string DE.print)
*)

(* [d] must be nullable.  Returns either [f (force d)] if d is not null,
 * or NULL (of the same type than that returned by [f]). *)
(* TODO: move all these functions into stdLib: *)
and propagate_null ?(depth=0) d_env d f =
  !logger.debug "%s...propagating null from %a"
    (indent_of depth)
    (DE.print ?max_depth:None) d ;
  let_ ~name:"nullable_" ~l:d_env d (fun d_env d ->
    let res = ensure_nullable ~d_env (f d_env (force d)) in
    let mn = mn_of_t (DE.type_of d_env res) in
    if_
      ~cond:(is_null d)
      ~then_:(null mn.DT.vtyp)
      (* Since [f] can return a nullable value already, rely on
       * [conv_maybe_nullable_from] to do the right thing instead of
       * [not_null]: *)
      ~else_:res)

(* [apply_1] takes a DIL expression and propagate null or apply [f] on it.
 * Unlike [propagate_null], also works on non-nullable values.
 * Also optionally convert the input before passing it to [f] *)
and apply_1 ?depth ?convert_in d_env d1 f =
  let no_prop d_env d1 =
    let d1 =
      match convert_in with
      | None -> d1
      | Some to_ -> conv ~to_ d_env d1 in
    f d_env d1 in
  let t1 = mn_of_t (DE.type_of d_env d1) in
  if t1.DT.nullable then
    propagate_null ?depth d_env d1 no_prop
  else
    no_prop d_env d1

(* Same as [apply_1] for two arguments: *)
and apply_2 ?(depth=0) ?convert_in ?(enlarge_in=false)
            d_env d1 d2 f =
  assert (convert_in = None || not enlarge_in) ;
  (* When neither d1 nor d2 are nullable: *)
  let conv d_env d =
    match convert_in with
    | None -> d
    | Some to_ -> conv ~to_ d_env d in
  (* neither d1 nor d2 are nullable at that point: *)
  let no_prop d_env d1 d2 =
    let d1, d2 =
      if convert_in <> None then
        conv d_env d1, conv d_env d2
      else if enlarge_in then
        let t1 = mn_of_t (DE.type_of d_env d1)
        and t2 = mn_of_t (DE.type_of d_env d2) in
        let vtyp = T.largest_type [ t1.vtyp ; t2.vtyp ] in
        conv_maybe_nullable ~to_:DT.{ t1 with vtyp } d_env d1,
        conv_maybe_nullable ~to_:DT.{ t2 with vtyp } d_env d2
      else d1, d2 in
    f d_env d1 d2 in
  (* d1 is not nullable at this stage: *)
  let no_prop_d1 d_env d1 =
    let t2 = mn_of_t (DE.type_of d_env d2) in
    if t2.DT.nullable then
      propagate_null ~depth d_env d2 (fun d_env d2 -> no_prop d_env d1 d2)
    else
      (* neither d1 nor d2 is nullable so no need to propagate nulls: *)
      no_prop d_env d1 d2 in
  let t1 = mn_of_t (DE.type_of d_env d1) in
  if t1.DT.nullable then (
    propagate_null ~depth d_env d1 no_prop_d1
  ) else (
    no_prop_d1 d_env d1
  )

(* Update the state(s) used by the expression [e]. *)
let update_state_for_expr ~r_env ~d_env ~what e =
  let with_state ~d_env state_rec e f =
    let open DE.Ops in
    let state = get_state state_rec e in
    let_ ~name:"state" ~l:d_env state f in
  (* Either call [f] with a DIL variable holding the (forced, if [skip_nulls])
   * value of [e], or do nothing if [skip_nulls] and [e] is null: *)
  let with_expr ~skip_nulls d_env e f =
    let d = expression ~r_env ~d_env e in
    let_ ~name:"state_update_expr" ~l:d_env d (fun d_env d ->
      match DE.type_of d_env d, skip_nulls with
      | DT.Value { nullable = true ; _ }, true ->
          if_
            ~cond:(is_null d)
            ~then_:nop
            ~else_:(let_ ~name:"forced_op" ~l:d_env (force d) f)
      | _ ->
          f d_env d) in
  let with_exprs ~skip_nulls d_env es f =
    let rec loop d_env ds = function
      | [] ->
          f d_env []
      | [ e ] ->
          with_expr ~skip_nulls d_env e (fun d_env d ->
            f d_env (List.rev (d :: ds)))
      | e :: es ->
          with_expr ~skip_nulls d_env e (fun d_env d ->
            loop d_env (d :: ds) es) in
    loop d_env [] es in
  let cmt = "update state for "^ what in
  E.unpure_fold [] (fun _s lst e ->
    let convert_in = e.E.typ.DT.vtyp in
    let may_set ~d_env state_rec new_state =
      if DT.eq DT.void (DE.type_of d_env new_state) then
        new_state
      else
        set_state state_rec e new_state in
    match e.E.text with
    | Stateful (_, _, SF1 (_, e1)) when E.is_a_list e1 ->
        (* Those are not actually stateful, see [expression] where those are
         * handled as stateless operators. *)
        lst
    | Stateful (state_lifespan, skip_nulls, SF1 (aggr, e1)) ->
        let state_rec = pick_state r_env e state_lifespan in
        with_expr ~skip_nulls d_env e1 (fun d_env d1 ->
          with_state ~d_env state_rec e (fun d_env state ->
            let new_state = update_state_sf1 ~d_env ~convert_in aggr
                                             d1 state in
            may_set ~d_env state_rec new_state)
        ) :: lst
    | Stateful (state_lifespan, skip_nulls, SF2 (aggr, e1, e2)) ->
        let state_rec = pick_state r_env e state_lifespan in
        with_expr ~skip_nulls d_env e1 (fun d_env d1 ->
          with_expr ~skip_nulls d_env e2 (fun d_env d2 ->
            with_state ~d_env state_rec e (fun d_env state ->
              let new_state = update_state_sf2 ~d_env ~convert_in aggr
                                               d1 d2 state in
              may_set ~d_env state_rec new_state))
        ) :: lst
    | Stateful (state_lifespan, skip_nulls, SF4s (aggr, e1, e2, e3, e4s)) ->
        let state_rec = pick_state r_env e state_lifespan in
        with_expr ~skip_nulls d_env e1 (fun d_env d1 ->
          with_expr ~skip_nulls d_env e2 (fun d_env d2 ->
            with_expr ~skip_nulls d_env e3 (fun d_env d3 ->
              with_exprs ~skip_nulls d_env e4s (fun d_env d4s ->
                with_state ~d_env state_rec e (fun d_env state ->
                  let new_state = update_state_sf4s ~d_env ~convert_in aggr
                                                    d1 d2 d3 d4s state in
                  may_set ~d_env state_rec new_state))))
        ) :: lst
    | Stateful (state_lifespan, skip_nulls, Past { what ; time ; tumbling ; _ }) ->
        let state_rec = pick_state r_env e state_lifespan in
        with_expr ~skip_nulls d_env what (fun d_env what ->
          with_expr ~skip_nulls d_env time (fun d_env time ->
            with_state ~d_env state_rec e (fun d_env state ->
              let v_t = lst_item_type e in
              let new_state = update_state_past ~d_env ~convert_in
                                                tumbling what time state v_t in
              may_set ~d_env state_rec new_state))
        ) :: lst
    | Stateful (state_lifespan, skip_nulls,
                Top { what ; by ; time ; duration ; _ }) ->
        let state_rec = pick_state r_env e state_lifespan in
        with_expr ~skip_nulls d_env what (fun d_env what ->
          with_expr ~skip_nulls d_env by (fun d_env by ->
            with_expr ~skip_nulls d_env time (fun d_env time ->
              with_expr ~skip_nulls d_env duration (fun d_env duration ->
                with_state ~d_env state_rec e (fun d_env state ->
                  let decay =
                    neg (force (div (force (log_ (float 0.5)))
                                    (mul (float 0.5) (to_float duration)))) in
                  let_ ~name:"decay" ~l:d_env decay (fun d_env decay ->
                    let new_state = update_state_top ~d_env ~convert_in
                                                     what by decay time state in
                    may_set ~d_env state_rec new_state)))))
        ) :: lst
    | Stateful _ ->
        todo "update_state"
    | _ ->
        invalid_arg "update_state"
  ) e |>
  List.rev |>
  seq |>
  comment cmt

(* Augment the given compilation unit with some external identifiers required to
 * implement some of the RaQL expressions: *)
let init compunit =
  (* Some helper functions *)
  let compunit =
    let name = "CodeGenLib.uuid_of_u128"
    and t = DT.(Function ([| DT.u128 |], DT.string)) in
    DU.add_external_identifier compunit name t in
  compunit
