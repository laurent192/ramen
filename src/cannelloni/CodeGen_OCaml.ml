(* Code generator for OCaml.
 * We do not use a templating system because thanks to libraries the generated
 * code should be minimal and limited to the less constant pieces of code.
 *)

(* Each operation must be implemented for OCaml which is used both as a
 * prototyping language and as a reference implementation. Some operations may
 * also exist for other languages.
 *)

(* Regarding generated code names: all generated OCaml identifier has a name
 * ending with underscore.  In addition, tuple field names are prefixed by
 * the tuple name. *)

open Batteries
open RamenLog
open RamenSharedTypes
open Lang
open Helpers
module C = RamenConf

let id_of_prefix tuple =
  String.nreplace (string_of_prefix tuple) "." "_"

(* Tuple deconstruction as a function parameter: *)
let id_of_field_name ?(tuple=TupleIn) = function
  | "#count" -> "virtual_"^ id_of_prefix tuple ^"_count_"
  | "#successive" -> "virtual_"^ id_of_prefix tuple ^"_successive_"
  | field -> id_of_prefix tuple ^"_"^ field ^"_"

let id_of_field_typ ?tuple field_typ =
  id_of_field_name ?tuple field_typ.typ_name

let list_print_as_tuple = List.print ~first:"(" ~last:")" ~sep:", "

let print_tuple_deconstruct tuple =
  let print_field fmt field_typ =
      String.print fmt (id_of_field_typ ~tuple field_typ)
  in
  list_print_as_tuple print_field

(* Emit the code that return the sersize of a fixed size type *)
let emit_sersize_of_fixsz_typ oc typ =
  let sz = RingBufLib.sersize_of_fixsz_typ typ in
  Int.print oc sz

(* Emit the code computing the sersize of some variable *)
let emit_sersize_of_field_var typ oc var =
  match typ with
  | TString ->
    Printf.fprintf oc "\
      (%d + RingBufLib.round_up_to_rb_word(String.length %s))"
      RingBufLib.rb_word_bytes var
  | _ -> emit_sersize_of_fixsz_typ oc typ

(* Emit the code to retrieve the sersize of some serialized value *)
let rec emit_sersize_of_field_tx tx_var offs_var nulli oc field =
  if field.nullable then (
    Printf.fprintf oc "if RingBuf.get_bit %s %d then %a else 0"
      tx_var nulli
      (emit_sersize_of_field_tx tx_var offs_var nulli) { field with nullable = false }
  ) else match field.typ with
    | TString ->
      Printf.fprintf oc "\
        %d + RingBufLib.round_up_to_rb_word(RingBuf.read_word %s %s)"
        RingBufLib.rb_word_bytes tx_var offs_var
    | _ -> emit_sersize_of_fixsz_typ oc field.typ

let id_of_typ typ =
  match typ with
  | TFloat  -> "float"
  | TString -> "string"
  | TBool   -> "bool"
  | TU8     -> "u8"
  | TU16    -> "u16"
  | TU32    -> "u32"
  | TU64    -> "u64"
  | TU128   -> "u128"
  | TI8     -> "i8"
  | TI16    -> "i16"
  | TI32    -> "i32"
  | TI64    -> "i64"
  | TI128   -> "i128"
  | TNull   -> "null"
  | TEth    -> "eth"
  | TIpv4   -> "ip4"
  | TIpv6   -> "ip6"
  | TCidrv4 -> "cidr4"
  | TCidrv6 -> "cidr6"
  | TNum    -> assert false

let emit_value_of_string typ oc var =
  Printf.fprintf oc "CodeGenLib.%s_of_string %s" (id_of_typ typ) var

let emit_sersize_of_tuple name oc tuple_typ =
  (* For nullable fields each ringbuf record has a bitmask of as many bits as
   * there are nullable fields, rounded to the greater or equal multiple of rb_word_size.
   * This is a constant given by the tuple type:
   *)
  let size_for_nullmask = RingBufLib.nullmask_bytes_of_tuple_type tuple_typ in
  (* Let's emit the function definition, deconstructing the tuple with identifiers
   * for varsized fields: *)
  Printf.fprintf oc "let %s %a =\n\t\
      %d (* null bitmask *) + %a\n"
    name
    (print_tuple_deconstruct TupleOut) tuple_typ
    size_for_nullmask
    (List.print ~first:"" ~last:"" ~sep:" + " (fun fmt field_typ ->
      let id = id_of_field_typ ~tuple:TupleOut field_typ in
      if field_typ.nullable then (
        Printf.fprintf fmt "(match %s with None -> 0 | Some x_ -> %a)"
          id
          (emit_sersize_of_field_var field_typ.typ) "x_"
      ) else (
        Printf.fprintf fmt "%a" (emit_sersize_of_field_var field_typ.typ) id
      ))) tuple_typ

let emit_set_value tx_var offs_var field_var oc field_typ =
  Printf.fprintf oc "RingBuf.write_%s %s %s %s"
    (id_of_typ field_typ) tx_var offs_var field_var

(* The function that will serialize the fields of the tuple at the given
 * addresses.  Everything else (allocating on the RB and writing the record
 * size) is independent of the tuple type and is handled in the library.
 * Also, the lib ensure that null bitmask is 0 at the beginning. Returns
 * the final offset for checking with serialized size of this tuple. *)
let emit_serialize_tuple name oc tuple_typ =
  Printf.fprintf oc "let %s tx_ %a =\n"
    name
    (print_tuple_deconstruct TupleOut) tuple_typ ;
  let nullmask_bytes = RingBufLib.nullmask_bytes_of_tuple_type tuple_typ in
  Printf.fprintf oc "\tlet offs_ = %d in\n" nullmask_bytes ;
  (* Start by zeroing the nullmask *)
  if nullmask_bytes > 0 then
    Printf.fprintf oc "\tRingBuf.zero_bytes tx_ 0 %d ; (* zero the nullmask *)\n"
      nullmask_bytes ;
  let _ = List.fold_left (fun nulli field ->
      let id = id_of_field_typ ~tuple:TupleOut field in
      if field.nullable then (
        (* Write either nothing (since the nullmask is initialized with 0) or
         * the nullmask bit and the value *)
        Printf.fprintf oc "\tlet offs_ = match %s with\n" id ;
        Printf.fprintf oc "\t| None -> offs_\n" ;
        Printf.fprintf oc "\t| Some x_ ->\n" ;
        Printf.fprintf oc "\t\tRingBuf.set_bit tx_ %d ;\n" nulli ;
        Printf.fprintf oc "\t\t%a ;\n"
          (emit_set_value "tx_" "offs_" "x_") field.typ ;
        Printf.fprintf oc "\t\toffs_ + %a in\n"
          (emit_sersize_of_field_var field.typ) "x_"
      ) else (
        Printf.fprintf oc "\t%a ;\n"
          (emit_set_value "tx_" "offs_" id) field.typ ;
        Printf.fprintf oc "\tlet offs_ = offs_ + %a in\n"
          (emit_sersize_of_field_var field.typ) id
      ) ;
      nulli + (if field.nullable then 1 else 0)
    ) 0 tuple_typ in
  Printf.fprintf oc "\toffs_\n"

(* Return the list of all other fields, in order *)
let get_star_fields out_tuple_typ selected_fields and_all_others =
  if not and_all_others then [] else
  (* We will iter through the selected fields, marking those which have been
   * outputted so that we do not output them again in the STAR operator. *)
  let outputted = List.fold_left (fun set sf ->
      match sf.Operation.expr with
      | Expr.Field (_, tuple, field) when !tuple = TupleIn ->
        Set.add field set
      | _ -> set
    ) Set.empty selected_fields in
  List.fold_left (fun lst field ->
      if Set.mem field.typ_name outputted then lst else field :: lst
    ) [] out_tuple_typ |>
  List.rev

let rec emit_indent oc n =
  if n > 0 then (
    Printf.fprintf oc "\t" ;
    emit_indent oc (n-1)
  )

(* Emit a function that, given an array of strings (corresponding to a line of
 * CSV) will return the tuple defined by [tuple_typ] or raises
 * some exception *)
let emit_tuple_of_strings name csv_null oc tuple_typ =
  Printf.fprintf oc "let %s strs_ =\n" name ;
  Printf.fprintf oc "\t(\n" ;
  let nb_fields = List.length tuple_typ in
  List.iteri (fun i field_typ ->
    let sep = if i < nb_fields - 1 then "," else "" in
    if field_typ.nullable then (
      Printf.fprintf oc "\t\t(let s_ = strs_.(%d) in\n" i ;
      Printf.fprintf oc "\t\tif s_ = %S then None else Some (%a))%s\n"
        csv_null
        (emit_value_of_string field_typ.typ) "s_"
        sep
    ) else (
      let s_var = Printf.sprintf "strs_.(%d)" i in
      Printf.fprintf oc "\t\t%a%s\n"
        (emit_value_of_string field_typ.typ) s_var sep
    )) tuple_typ ;
  Printf.fprintf oc "\t)\n"

(* Given a tuple type, generate the ReadCSVFile operation. *)
let emit_read_csv_file oc csv_fname unlink csv_separator csv_null tuple_typ
                       preprocessor =
  (* The dynamic part comes from the unpredictable field list.
   * For each input line, we want to read all fields and build a tuple.
   * Then we want to write this tuple in some ring buffer.
   * We need to generate these functions:
   * - reading a CSV string into a tuple type (when nullable fields are option type)
   * - given such a tuple, return its serialized size
   * - given a pointer toward the ring buffer, serialize the tuple *)
  Printf.fprintf oc "open Stdint\n\n\
    %a\n%a\n%a\n\
    let () =\n\
      \tLwt_main.run (\n\
      \t\tCodeGenLib.read_csv_file %S %b %S sersize_of_tuple_ serialize_tuple_ tuple_of_strings_ %S)\n"
    (emit_sersize_of_tuple "sersize_of_tuple_") tuple_typ
    (emit_serialize_tuple "serialize_tuple_") tuple_typ
    (emit_tuple_of_strings "tuple_of_strings_" csv_null) tuple_typ
    csv_fname unlink csv_separator preprocessor

let emit_tuple tuple oc tuple_typ =
  print_tuple_deconstruct tuple oc tuple_typ

let emit_in_tuple ?(tuple=TupleIn) mentioned and_all_others oc in_tuple_typ =
  print_tuple_deconstruct tuple oc (List.filter_map (fun field_typ ->
    if and_all_others || Set.mem field_typ.typ_name mentioned then
      Some field_typ else None) in_tuple_typ)

(* We do not want to read the value from the RB each time it's used,
 * so extract a tuple from the ring buffer. As an optimisation, read
 * (and return) only the mentioned fields. *)
let emit_read_tuple name mentioned and_all_others oc in_tuple_typ =
  Printf.fprintf oc "\
    let %s tx_ =\n\
    \tlet offs_ = %d in\n"
    name
    (RingBufLib.nullmask_bytes_of_tuple_type in_tuple_typ) ;
  let _ = List.fold_left (fun nulli field ->
      let id = id_of_field_typ ~tuple:TupleIn field in
      if and_all_others || Set.mem field.typ_name mentioned then (
        Printf.fprintf oc "\tlet %s =\n" id ;
        if field.nullable then
          Printf.fprintf oc "\
            \t\tif RingBuf.get_bit tx_ %d then\n\
            \t\t\tSome (RingBuf.read_%s tx_ offs_) else None in\n"
            nulli
            (id_of_typ field.typ)
        else
          Printf.fprintf oc "\
            \t\tRingBuf.read_%s tx_ offs_ in\n"
            (id_of_typ field.typ) ;
        Printf.fprintf oc "\tlet offs_ = " ;
        if field.nullable then
          Printf.fprintf oc
            "(match %s with None -> offs_ | Some %s -> offs_ + %a) in\n"
            id id
            (emit_sersize_of_field_var field.typ) id
        else
          Printf.fprintf oc "\
            offs_ + %a in\n"
            (emit_sersize_of_field_var field.typ) id ;
      ) else (
        Printf.fprintf oc "\tlet offs_ = offs_ + (%a) in\n"
          (emit_sersize_of_field_tx "tx_" "offs_" nulli) field
      ) ;
      nulli + (if field.nullable then 1 else 0)
    ) 0 in_tuple_typ in
  Printf.fprintf oc "\tignore offs_ ;\n" ; (* avoid a warning *)
  Printf.fprintf oc "\t%a\n"
    (emit_in_tuple mentioned and_all_others) in_tuple_typ

(* Returns the set of all field names from the "in" tuple mentioned
 * anywhere in the given expression: *)
let add_mentioned prev =
  let open Expr in
  fold_by_depth (fun prev e ->
    match e with
    | Field (_, tuple, field) when tuple_has_type_input !tuple ->
      Set.add field prev
    | _ -> prev) prev

let add_all_mentioned_in_expr lst =
  let rec loop prev = function
    | [] -> prev
    | e :: e' -> loop (add_mentioned prev e) e'
  in
  loop Set.empty lst

let add_all_mentioned_in_string mentioned _str =
  (* TODO! *)
  mentioned

let emit_scalar oc =
  let open Stdint in
  function
  | VFloat  f -> Printf.fprintf oc "%f" f
  | VString s -> Printf.fprintf oc "%S" s
  | VBool   b -> Printf.fprintf oc "%b" b
  | VU8     n -> Printf.fprintf oc "(Uint8.of_int %d)" (Uint8.to_int n)
  | VU16    n -> Printf.fprintf oc "(Uint16.of_int %d)" (Uint16.to_int n)
  | VU32    n -> Printf.fprintf oc "(Uint32.of_int64 %sL)" (Uint32.to_string n)
  | VU64    n -> Printf.fprintf oc "(Uint64.of_string %S)" (Uint64.to_string n)
  | VU128   n -> Printf.fprintf oc "(Uint128.of_string %S)" (Uint128.to_string n)
  | VI8     n -> Printf.fprintf oc "(Int8.of_int %d)" (Int8.to_int n)
  | VI16    n -> Printf.fprintf oc "(Int16.of_int %d)" (Int16.to_int n)
  | VI32    n -> Printf.fprintf oc "%sl" (Int32.to_string n)
  | VI64    n -> Printf.fprintf oc "%sL" (Int64.to_string n)
  | VI128   n -> Printf.fprintf oc "(Int128.of_string %S)" (Int128.to_string n)
  | VEth    n -> Printf.fprintf oc "(Uint40.of_int64 %LdL)" (Uint48.to_int64 n)
  | VIpv4   n -> Printf.fprintf oc "(Uint32.of_string %S)" (Uint32.to_string n)
  | VIpv6   n -> Printf.fprintf oc "(Uint128.of_string %S)" (Uint128.to_string n)
  | VCidrv4 (n,l) ->
                 Printf.fprintf oc "(Uint32.of_string %S, %d)" (Uint32.to_string n) l
  | VCidrv6 (n,l) ->
                 Printf.fprintf oc "(Uint128.of_string %S, %d)" (Uint128.to_string n) l
  | VNull     -> Printf.fprintf oc "()"

let funcname_of_expr =
  let open Expr in
  function
  | AggrMin _ -> "min"
  | AggrMax _ -> "max"
  | AggrPercentile _ -> "percentile"
  | AggrSum _ | Add _ -> "add"
  | AggrAnd _ | And _ -> "(&&)"
  | AggrOr _ | Or _ -> "(||)"
  | AggrFirst _ -> "(fun x _ -> x)"
  | AggrLast _ -> "(fun _ x -> x)"
  | Age _ -> "age"
  | Now _ -> "now"
  | Abs _ -> "abs"
  | Sequence _ -> "sequence"
  | Length _ -> "length"
  | Cast _ -> "identity"
  | Not _ -> "not"
  | Defined _ -> "defined"
  | Sub _ -> "sub"
  | Mul _ -> "mul"
  | Div _ | IDiv _ -> "div"
  | Mod _ -> "rem"
  | Pow _ -> "( ** )"
  | Ge _ -> "(>=)"
  | Gt _ -> "(>)"
  | Eq _ -> "(=)"
  | BeginOfRange _ -> "begin_of_range"
  | EndOfRange _ -> "end_of_range"
  | Lag _ -> "Seasonal.add"
  | MovingAvg _ | LinReg _ -> "Seasonal.add"
  | ExpSmooth _ -> "smooth"
  | Exp _ -> "exp"
  | Log _ -> "log"
  | Sqrt _ -> "sqrt"
  | Split _ -> "split"
  | Concat _ -> "(^)"
  | Const _ | Param _ | Field _ ->
    assert false

(* Given a function name and an output type, return the actual function
 * returning that type, and the type input parameters must be converted into,
 * if any. For function with several parameters this input type target is
 * either for all of them or some of them, depending on the function. This
 * is up to the caller. *)
let implementation_of expr =
  let open Expr in
  let name = funcname_of_expr expr in
  let out_typ = typ_of expr in
  match expr, out_typ.scalar_typ with
  | (AggrSum _|Add _|Sub _|Mul _|IDiv _|Div _|Abs _|Pow _|Exp _|Log _|Sqrt _), Some TFloat ->
    "BatFloat."^ name, Some TFloat
  | (AggrSum _|Add _|Sub _|Mul _|IDiv _|Mod _|Abs _), Some TU8 -> "Uint8."^ name, Some TU8
  | (AggrSum _|Add _|Sub _|Mul _|IDiv _|Mod _|Abs _), Some TU16 -> "Uint16."^ name, Some TU16
  | (AggrSum _|Add _|Sub _|Mul _|IDiv _|Mod _|Abs _), Some TU32 -> "Uint32."^ name, Some TU32
  | (AggrSum _|Add _|Sub _|Mul _|IDiv _|Mod _|Abs _), Some TU64 -> "Uint64."^ name, Some TU64
  | (AggrSum _|Add _|Sub _|Mul _|IDiv _|Mod _|Abs _), Some TU128 -> "Uint128."^ name, Some TU128
  | (AggrSum _|Add _|Sub _|Mul _|IDiv _|Mod _|Abs _), Some TI8 -> "Int8."^ name, Some TI8
  | (AggrSum _|Add _|Sub _|Mul _|IDiv _|Mod _|Abs _), Some TI16 -> "Int16."^ name, Some TI16
  | (AggrSum _|Add _|Sub _|Mul _|IDiv _|Mod _|Abs _), Some TI32 -> "Int32."^ name, Some TI32
  | (AggrSum _|Add _|Sub _|Mul _|IDiv _|Mod _|Abs _), Some TI64 -> "Int64."^ name, Some TI64
  | (AggrSum _|Add _|Sub _|Mul _|IDiv _|Mod _|Abs _), Some TI128 -> "Int128."^ name, Some TI128
  | Concat _, Some TString -> name, Some TString
  | Length _, Some TU16 (* The only possible output type *) -> "String."^ name, Some TString
  | (Not _|And _|Or _|AggrAnd _|AggrOr _), Some TBool -> name, Some TBool
  | (Ge _| Gt _| Eq _), Some TBool -> name, None (* No conversion necessary *)
  | (AggrMax _|AggrMin _|AggrFirst _|AggrLast _), _ -> name, None (* No conversion necessary *)
  | Age _, Some (TFloat|TU8|TU16|TU32|TU64|TU128|TI8|TI16|TI32|TI64|TI128 as to_typ)
  | BeginOfRange _, Some (TCidrv4 | TCidrv6 as to_typ) ->
    let in_type_name =
      String.lowercase (IO.to_string Scalar.print_typ to_typ) in
    "CodeGenLib."^ name ^"_"^ in_type_name, None
  | AggrPercentile _, Some (TFloat|TU8|TU16|TU32|TU64|TU128|TI8|TI16|TI32|TI64|TI128) ->
    "CodeGenLib."^ name, None
  (* TODO: Now() for Uint62? *)
  | Now _, Some TFloat -> "CodeGenLib."^ name, None
  | Lag _, _ -> "CodeGenLib."^ name, None
  (* We force the inputs to be float since we are going to return a float anyway. *)
  | (MovingAvg _|LinReg _|ExpSmooth _), Some TFloat -> "CodeGenLib."^ name, Some TFloat
  | Cast _, t -> "CodeGenLib."^ name, t
  (* Sequence build a sequence of as-large-as-convenient integers (signed or
   * not) *)
  | Sequence _, Some TI128 -> "CodeGenLib."^ name, Some TI128
  | Split _, Some TString -> "CodeGenLib."^ name, Some TString
  | _, Some to_typ ->
    failwith ("Cannot find implementation of "^ name ^" for type "^
              IO.to_string Scalar.print_typ to_typ)
  | _, None ->
    assert false

let name_of_state =
  let open Expr in
  function
  (* TODO: use the op name in the field name to help debugging *)
  | AggrMin (t, _) | AggrMax (t, _) | AggrPercentile (t, _, _)
  | AggrSum (t, _) | AggrAnd (t, _) | AggrOr (t, _) | AggrFirst (t, _)
  | AggrLast (t, _) | Lag (t, _, _) | MovingAvg (t, _, _, _)
  | LinReg (t, _, _, _) | ExpSmooth (t, _, _) ->
    "field_"^ string_of_int t.uniq_num
  | Const _ | Param _ | Field _ | Age _ | Sequence _ | Not _ | Defined _
  | Add _ | Sub _ | Mul _ | Div _ | IDiv _ | Pow _ | And _ | Or _ | Ge _
  | Gt _ | Eq _ | Mod _ | Cast _ | Abs _ | Length _ | Now _ | Concat _
  | BeginOfRange _ | EndOfRange _ | Exp _ | Log _ | Sqrt _ | Split _ ->
    assert false

let otype_of_type = function
  | TFloat -> "float" | TString -> "string" | TBool -> "bool"
  | TU8 -> "uint8" | TU16 -> "uint16" | TU32 -> "uint32" | TU64 -> "uint64" | TU128 -> "uint128"
  | TI8 -> "int8" | TI16 -> "int16" | TI32 -> "int32" | TI64 -> "int64" | TI128 -> "int128"
  | TNull -> "unit"
  | TEth -> "uint48"
  | TIpv4 -> "uint32"
  | TIpv6 -> "uint128"
  | TCidrv4 -> "(uint32 * int)"
  | TCidrv6 -> "(uint128 * int)"
  | TNum -> assert false

let otype_of_state e =
  let open Expr in
  let typ = typ_of e in
  let t = Option.get typ.scalar_typ |>
          otype_of_type in
  let t =
    match e with
    | AggrPercentile _ -> t ^" list"
    (* previous tuples and count ; Note: we could get rid of this count if we
     * provided some context to those functions, such as the event count in
     * current window, for instance (ie. pass the full aggr record not just
     * the fields) *)
    | Lag _ | MovingAvg _ | LinReg _ -> t ^" CodeGenLib.Seasonal.t"
    | _ -> t in
  if Option.get typ.nullable then t ^" option" else t

let omod_of_type = function
  | TFloat -> "BatFloat"
  | TString -> "BatString"
  | TBool -> "BatBool"
  | TU8 | TU16 | TU32 | TU64 | TU128
  | TI8 | TI16 | TI32 | TI64 | TI128
  | TEth | TIpv4 | TIpv6 as t ->
    String.capitalize (otype_of_type t)
  | TCidrv4 | TCidrv6 -> assert false (* Must not be used since no conversion from/to those *)
  | TNull -> assert false (* Never used on NULLs *)
  | TNum -> assert false

(* TODO: Why don't we have explicit casts in the AST so that wqe could stop caring
 * about those pesky conversions once and for all? *)
let conv_from_to from_typ ~nullable to_typ p fmt e =
  match from_typ, to_typ with
  | a, b when a = b -> p fmt e
  | (TU8|TU16|TU32|TU64|TU128|TI8|TI16|TI32|TI64|TI128|TString|TFloat),
      (TU8|TU16|TU32|TU64|TU128|TI8|TI16|TI32|TI64|TI128)
  | TString, (TFloat|TBool) ->
    Printf.fprintf fmt "(%s%s.of_%s %a)"
      (if nullable then "BatOption.map " else "")
      (omod_of_type to_typ)
      (otype_of_type from_typ)
      p e
  | (TU8|TU16|TU32|TU64|TU128|TI8|TI16|TI32|TI64|TI128),
      (TFloat|TString)
  | (TFloat|TBool), TString ->
    Printf.fprintf fmt "(%s%s.to_%s %a)"
      (if nullable then "BatOption.map " else "")
      (omod_of_type from_typ)
      (otype_of_type to_typ)
      p e
  | _, TNull ->
    (* We could as well just print "()" but this is easier for debugging,
     * and hopefully the compiler will make it the same: *)
    Printf.fprintf fmt "(ignore %a)" p e
  | _ ->
    failwith (Printf.sprintf "Cannot find converter from type %s to type %s"
                (IO.to_string Scalar.print_typ from_typ)
                (IO.to_string Scalar.print_typ to_typ))

let freevar_name t = "fv_"^ string_of_int t.Expr.uniq_num ^"_"

(* Implementation_of gives us the type operands must be converted to.
 * This printer wrap an expression into a converter according to its current
 * type. *)
let rec conv_to ?finalize ?state to_typ fmt e =
  let open Expr in
  let t = typ_of e in
  let nullable = Option.get t.nullable in
  match t.scalar_typ, to_typ with
  | Some a, Some b -> conv_from_to a ~nullable b (emit_expr ?finalize ?state) fmt e
  | _, None -> (emit_expr ?finalize ?state) fmt e (* No conversion required *)
  | None, Some b ->
    failwith (Printf.sprintf "Cannot convert from unknown type into %s"
                (IO.to_string Scalar.print_typ b))

(* state is just the name of the state record to use, or None if we must
 * assume the field name is actually already present in the environment
 * (as is the case in aggr_init) *)
and emit_expr ?(finalize=true) ?(state=true) oc =
  let record_of_state = if state then "aggr_." else "" in
  let open Expr in
  function
  | Const (_, c) ->
    emit_scalar oc c
  | Field (_, tuple, field) ->
    let tuple = !tuple in
    String.print oc (id_of_field_name ~tuple field)
  | Param _ ->
    failwith "TODO: code gen for params"
  | AggrPercentile (_, pct, _) as expr when finalize ->
    Printf.fprintf oc "(CodeGenLib.percentile_finalize (%a) %s%s)"
      (conv_to ~finalize ~state (Some TFloat)) pct
      record_of_state
      (name_of_state expr)
  | Lag _ as expr when finalize ->
    Printf.fprintf oc "(CodeGenLib.Seasonal.lag %s%s)"
      record_of_state (name_of_state expr)
  | MovingAvg (_, p, n, _) as expr when finalize ->
    Printf.fprintf oc
      "(CodeGenLib.Seasonal.avg (Uint16.to_int %a) (Uint16.to_int %a) %s%s)"
      (conv_to ~finalize ~state (Some TU16)) p
      (conv_to ~finalize ~state (Some TU16)) n
      record_of_state (name_of_state expr)
  | LinReg (_, p, n, _) as expr when finalize ->
    Printf.fprintf oc
      "(CodeGenLib.Seasonal.linreg (Uint16.to_int %a) (Uint16.to_int %a) %s%s)"
      (conv_to ~finalize ~state (Some TU16)) p
      (conv_to ~finalize ~state (Some TU16)) n
      record_of_state (name_of_state expr)
  | AggrMin _ | AggrMax _ | AggrSum _ | AggrAnd _ | AggrOr _ | AggrFirst _
  | AggrLast _ | ExpSmooth _ | AggrPercentile _ | Lag _ | MovingAvg _
  | LinReg _ as expr ->
     Printf.fprintf oc "%s%s" record_of_state (name_of_state expr)
  | Now _ as expr -> emit_function0 expr oc
  | Age (_, e) | Not (_, e) | Cast (_, e) | Abs (_, e)
  | Length (_, e) | BeginOfRange (_, e) | EndOfRange (_, e)
  | Exp (_, e) | Log (_, e) | Sqrt (_, e) as expr ->
    emit_function1 ~finalize ~state expr oc e
  | Defined (_, e) ->
    Printf.fprintf oc "(%a <> None)" (emit_expr ~finalize ~state) e
  | Add (_, e1, e2) | Sub (_, e1, e2) | Mul (_, e1, e2) | Concat (_, e1, e2)
  | Div (_, e1, e2) | IDiv (_, e1, e2) | Pow (_, e1, e2) | And (_, e1, e2)
  | Or (_, e1, e2) | Ge (_, e1, e2) | Gt (_, e1, e2) | Eq (_, e1, e2)
  | Sequence (_, e1, e2) | Mod (_, e1, e2) as expr ->
    emit_function2 ~finalize ~state expr oc e1 e2
  (* Generators: emit them as a free variable *)
  | Split (t, _, _) ->
    String.print oc (freevar_name t)

and emit_function0 expr oc =
  let impl, _ = implementation_of expr in
  Printf.fprintf oc "(%s ())" impl

and emit_function1 ?finalize ?state expr oc e =
  let impl, arg_typ = implementation_of expr in
  Printf.fprintf oc "(%s%s %a)"
    (if Expr.is_nullable e then "BatOption.map " else "")
    impl
    (conv_to ?finalize ?state arg_typ) e

and promote_to_same_types = function
  | None, None -> None
  | Some t1, None -> Some t1
  | None, Some t2 -> Some t2
  | Some t1, Some t2 -> Some (Scalar.larger_type (t1, t2))

(* When we combine nullable arguments we want to shortcut as much as
 * possible and avoid evaluating any of them if one is null. Here we will just
 * evaluate them in order until one is found to be nullable and null, or until
 * we evaluated them all, and then only we call the function.
 * TODO: ideally * we'd like to evaluate the nullable arguments first. *)
and emit_functionN ?finalize ?state impl arg_typ oc es =
  let open Expr in
  let len, has_nullable =
    List.fold_left (fun (i, had_nullable) e ->
        if is_nullable e then (
          Printf.fprintf oc "(match %a with None -> None | Some x%d_ -> "
            (conv_to ?finalize ?state arg_typ) e
            i ;
          i + 1, true
        ) else (
          Printf.fprintf oc "(let x%d_ = %a in "
            i
            (conv_to ?finalize ?state arg_typ) e ;
          i + 1, had_nullable
        )
      ) (0, false) es
  in
  Printf.fprintf oc "%s(%s" (if has_nullable then "Some" else "") impl ;
  for i = 0 to len-1 do Printf.fprintf oc " x%d_" i done ;
  for _i = 0 to len do Printf.fprintf oc ")" done

and emit_function2 ?finalize ?state expr oc e1 e2 =
  let impl, arg_typ = implementation_of expr in
  (* When we have no conversion to do, e1 and e2 still have to have the same type or
   * the compiler will complain so we promote: *)
  let open Expr in
  let arg_typ =
    if arg_typ <> None then arg_typ
    else promote_to_same_types ((typ_of e1).scalar_typ, (typ_of e2).scalar_typ)
  in
  emit_functionN ?finalize ?state impl arg_typ oc [e1; e2]

and emit_function3 ?finalize ?state expr oc e1 e2 e3 =
  let impl, arg_typ = implementation_of expr in
  (* When we have no conversion to do, e1, e2 and e3 still have to have the
   * same type or the compiler will complain so we promote: *)
  let open Expr in
  let arg_typ =
    if arg_typ <> None then arg_typ
    else promote_to_same_types (
           promote_to_same_types ((typ_of e1).scalar_typ, (typ_of e2).scalar_typ),
           (typ_of e3).scalar_typ)
  in
  emit_functionN ?finalize ?state impl arg_typ oc [e1; e2; e3]

(* We know that somewhere in expr we have one or several generators.
 * First we transform the AST to move the generators to the root,
 * and insert "free variables" (named after the generator uniq_num)
 * where the generator used to stand. Once this is done, the AST
 * start with a chain of generator, and then an expression that is
 * free of generators. We want to emit:
 * (fun k -> gen1 (fun fv1 -> gen2 (fun fv2 -> ... -> genN (fun fvN ->
 *    k (expr ...)))))
 *)
let emit_generator user_fun oc expr =
  let open Expr in

  let rec replace_unary prev e1 make =
    let prev, e1 = replace prev e1 in
    prev, make e1
  and replace_binary prev e1 e2 make =
    let prev, e1 =
      if is_generator e1 then replace prev e1
      else prev, e1 in
    let prev, e2 =
      if is_generator e2 then replace prev e2
      else prev, e2 in
    prev, make e1 e2

  (* Returns a list of generators. FIXME: an the same expression,
   * that not modified any more. simplify! *)
  and replace prev = function
    (* No subexpressions: *)
    | Const _ | Field _ | Param _ | Now _ -> assert false
    (* Forbidden within stateful functions: *)
    | AggrMin _ | AggrMax _ | AggrSum _ | AggrAnd _ | AggrOr _
    | AggrFirst _ | AggrLast _ | AggrPercentile _ | Lag  _
    | MovingAvg _ | LinReg _ | ExpSmooth _ ->
      assert false
    (* No generator, look deeper *)
    | Age (t, e1) -> replace_unary prev e1 (fun e1 -> Age (t, e1))
    | Cast (t, e1) -> replace_unary prev e1 (fun e1 -> Cast (t, e1))
    | Length (t, e1) -> replace_unary prev e1 (fun e1 -> Length (t, e1))
    | Not (t, e1) -> replace_unary prev e1 (fun e1 -> Not (t, e1))
    | Abs (t, e1) -> replace_unary prev e1 (fun e1 -> Abs (t, e1))
    | Defined (t, e1) -> replace_unary prev e1 (fun e1 -> Defined (t, e1))
    | Exp (t, e1) -> replace_unary prev e1 (fun e1 -> Exp (t, e1))
    | Log (t, e1) -> replace_unary prev e1 (fun e1 -> Log (t, e1))
    | Sqrt (t, e1) -> replace_unary prev e1 (fun e1 -> Sqrt (t, e1))
    | BeginOfRange (t, e1) -> replace_unary prev e1 (fun e1 -> BeginOfRange (t, e1))
    | EndOfRange (t, e1) -> replace_unary prev e1 (fun e1 -> EndOfRange (t, e1))
    (* No generator, look deeper in both directions *)
    | Sequence (t, e1, e2) -> replace_binary prev e1 e2 (fun e1 e2 -> Sequence (t, e1, e2))
    | Add (t, e1, e2) -> replace_binary prev e1 e2 (fun e1 e2 -> Add (t, e1, e2))
    | Sub (t, e1, e2) -> replace_binary prev e1 e2 (fun e1 e2 -> Sub (t, e1, e2))
    | Mul (t, e1, e2) -> replace_binary prev e1 e2 (fun e1 e2 -> Mul (t, e1, e2))
    | Div (t, e1, e2) -> replace_binary prev e1 e2 (fun e1 e2 -> Div (t, e1, e2))
    | IDiv (t, e1, e2) -> replace_binary prev e1 e2 (fun e1 e2 -> IDiv (t, e1, e2))
    | Mod (t, e1, e2) -> replace_binary prev e1 e2 (fun e1 e2 -> Mod (t, e1, e2))
    | Pow (t, e1, e2) -> replace_binary prev e1 e2 (fun e1 e2 -> Pow (t, e1, e2))
    | And (t, e1, e2) -> replace_binary prev e1 e2 (fun e1 e2 -> And (t, e1, e2))
    | Or (t, e1, e2) -> replace_binary prev e1 e2 (fun e1 e2 -> Or (t, e1, e2))
    | Ge (t, e1, e2) -> replace_binary prev e1 e2 (fun e1 e2 -> Ge (t, e1, e2))
    | Gt (t, e1, e2) -> replace_binary prev e1 e2 (fun e1 e2 -> Gt (t, e1, e2))
    | Eq (t, e1, e2) -> replace_binary prev e1 e2 (fun e1 e2 -> Eq (t, e1, e2))
    | Concat (t, e1, e2) -> replace_binary prev e1 e2 (fun e1 e2 -> Concat (t, e1, e2))
    (* Bingo! *)
    | Split (t, e1, e2) as expr ->
      let prev = expr :: prev in (* Inner generator first: *)
      replace_binary prev e1 e2 (fun e1 e2 -> Split (t, e1, e2))
  in
  (* Now we start with all the generator. Inner generators are first,
   * so we can confidently call emit_expr on the arguments and if this uses a
   * free variable it should be defined already: *)
  let emit_gen_root oc = function
    | Split (t, by, e) as expr ->
      let impl, arg_typ = implementation_of expr in
      Printf.fprintf oc "%s %a %a (fun %s -> "
        impl
        (conv_to ~finalize:true ~state:true arg_typ) by
        (conv_to ~finalize:true ~state:true arg_typ) e
        (freevar_name t)
    (* We have no other generators *)
    | _ -> assert false
  in
  let generators, e = replace [] expr in
  List.iter (emit_gen_root oc) generators ;
  (* Finally, call user_func on the actual expression, where all generators will
   * be replaced by their free variable: *)
  Printf.fprintf oc "%s (%a)"
    user_fun
    (emit_expr ~finalize:true ~state:true) e ;
  List.iter (fun _ -> Printf.fprintf oc ")") generators

let emit_generate_tuples name in_tuple_typ mentioned and_all_others out_tuple_typ oc selected_fields =
  let has_generator =
    List.exists (fun sf ->
      Expr.is_generator sf.Operation.expr)
      selected_fields in
  if not has_generator then
    Printf.fprintf oc "let %s f_ _it_ ot_ = f_ ot_ \n" name
  else (
    Printf.fprintf oc "let %s f_ %a %a =\n"
      name
      (emit_in_tuple mentioned and_all_others) in_tuple_typ
      (print_tuple_deconstruct TupleOut) out_tuple_typ ;
    (* Each generator is a functional receiving the continuation and calling it
     * as many times as there are values. *)
    let nb_gens =
      List.fold_left (fun nb_gens sf ->
          if not (Expr.is_generator sf.Operation.expr) then nb_gens
          else (
            let ff_ = "ff_"^ string_of_int nb_gens ^"_" in
            Printf.fprintf oc "%a(fun %s -> %a) (fun generated_%d_ ->\n"
              emit_indent (1 + nb_gens)
              ff_
              (emit_generator ff_) sf.Operation.expr
              nb_gens ;
            nb_gens + 1)
        ) 0 selected_fields in
    (* Now we have all the generated values, actually call f_ on the tuple *)
    Printf.fprintf oc "%af_ (\n%a"
      emit_indent (1 + nb_gens)
      emit_indent (2 + nb_gens) ;
    let _ = List.fold_lefti (fun gi i sf ->
        if i > 0 then Printf.fprintf oc ",\n%a" emit_indent (2 + nb_gens) ;
        if Expr.is_generator sf.Operation.expr then (
          Printf.fprintf oc "generated_%d_" gi ;
          gi + 1
        ) else (
          Printf.fprintf oc "%s"
            (id_of_field_name ~tuple:TupleOut sf.Operation.alias) ;
          gi
        )) 0 selected_fields in
    get_star_fields out_tuple_typ selected_fields and_all_others |>
    List.iter (fun field ->
      Printf.fprintf oc ",\n%a%s"
      emit_indent (2 + nb_gens)
      (id_of_field_name field.typ_name)) ;
    for _ = 1 to nb_gens do Printf.fprintf oc ")" done ;
    Printf.fprintf oc ")\n"
  )

let emit_field_of_tuple name mentioned and_all_others oc in_tuple_typ =
  Printf.fprintf oc "let %s %a = function\n"
    name
    (emit_in_tuple mentioned and_all_others) in_tuple_typ ;
  List.iter (fun field_typ ->
      if and_all_others || Set.mem field_typ.typ_name mentioned then (
        Printf.fprintf oc "\t| %S -> " field_typ.typ_name ;
        let id = id_of_field_name field_typ.typ_name in
        if field_typ.nullable then (
          Printf.fprintf oc "(match %s with None -> \"?null?\" | Some v_ -> %a)\n"
            id
            (conv_from_to field_typ.typ ~nullable:false TString String.print) "v_"
        ) else (
          Printf.fprintf oc "%a\n"
            (conv_from_to field_typ.typ ~nullable:false TString String.print) id
        )
      )
    ) in_tuple_typ ;
  Printf.fprintf oc "\t| _ -> raise Not_found\n"

let emit_where
      ?(with_group=false) ?(always_true=false)
      name in_tuple_typ mentioned and_all_others oc expr =
  Printf.fprintf oc "let %s virtual_in_count_ %a %a \
                       virtual_selected_count_ virtual_selected_successive_ %a \
                       virtual_unselected_count_ virtual_unselected_successive_ %a "
    name
    (emit_in_tuple mentioned and_all_others) in_tuple_typ
    (emit_in_tuple ~tuple:TupleLastIn mentioned and_all_others) in_tuple_typ
    (emit_in_tuple ~tuple:TupleLastSelected mentioned and_all_others) in_tuple_typ
    (emit_in_tuple ~tuple:TupleLastUnselected mentioned and_all_others) in_tuple_typ ;
  if with_group then
    Printf.fprintf oc "virtual_group_count_ virtual_group_successive_ aggr_ %a %a "
      (emit_in_tuple ~tuple:TupleGroupFirst mentioned and_all_others) in_tuple_typ
      (emit_in_tuple ~tuple:TupleGroupLast mentioned and_all_others) in_tuple_typ ;
  if always_true then
    Printf.fprintf oc "= true\n"
  else
    Printf.fprintf oc "=\n\t%a\n" (emit_expr ~finalize:true ~state:true) expr

(* If with aggr we have the aggregate record as first parameter
 * and also the first and last incoming tuple of this aggr as additional
 * parameters *)
let emit_field_selection
      ?(with_selected=false) (* and unselected *)
      ?(with_group=false)
      name in_tuple_typ mentioned
      and_all_others out_tuple_typ oc selected_fields =
  Printf.fprintf oc "let %s virtual_in_count_ %a %a "
    name
    (emit_in_tuple mentioned and_all_others) in_tuple_typ
    (emit_in_tuple ~tuple:TupleLastIn mentioned and_all_others) in_tuple_typ ;
  if with_selected then
    Printf.fprintf oc "virtual_selected_count_ virtual_selected_successive_ %a \
                       virtual_unselected_count_ virtual_unselected_successive_ %a "
      (emit_in_tuple ~tuple:TupleLastSelected mentioned and_all_others) in_tuple_typ
      (emit_in_tuple ~tuple:TupleLastUnselected mentioned and_all_others) in_tuple_typ ;
  if with_group then
    Printf.fprintf oc "virtual_out_count \
                       virtual_group_count_ virtual_group_successive_ aggr_ %a %a "
      (emit_in_tuple ~tuple:TupleGroupFirst mentioned and_all_others) in_tuple_typ
      (emit_in_tuple ~tuple:TupleGroupLast mentioned and_all_others) in_tuple_typ ;
  Printf.fprintf oc "=\n" ;
  List.iter (fun sf ->
      if Expr.is_generator sf.Operation.expr then
        (* So that we have a single out_tuple_typ both before and after tuples generation *)
        Printf.fprintf oc "\tlet %s = () in\n"
          (id_of_field_name ~tuple:TupleOut sf.Operation.alias)
      else
        Printf.fprintf oc "\tlet %s = %a in\n"
          (id_of_field_name ~tuple:TupleOut sf.Operation.alias)
          (emit_expr ~finalize:true ~state:true) sf.Operation.expr
    ) selected_fields ;
  Printf.fprintf oc "\t(\n\t\t" ;
  List.iteri (fun i sf ->
      Printf.fprintf oc "%s%s"
        (if i > 0 then ",\n\t\t" else "")
        (id_of_field_name ~tuple:TupleOut sf.Operation.alias) ;
    ) selected_fields ;
  get_star_fields out_tuple_typ selected_fields and_all_others |>
  List.iteri (fun i field ->
    Printf.fprintf oc "%s\n\t\t%s%s"
      (if i > 0 || selected_fields <> [] then "," else "")
      (if i = 0 then "(* All other fields *)\n\t\t" else "")
      (id_of_field_name field.typ_name)) ;
  Printf.fprintf oc "\n\t)\n"

(* Similar to emit_field_selection but with less options, no concept of star and no
 * naming of the fields as the fields from out, since that's not the out tuple
 * we are constructing: *)
let emit_key_of_input name in_tuple_typ mentioned and_all_others oc exprs =
  Printf.fprintf oc "let %s %a =\n\t("
    name
    (emit_in_tuple mentioned and_all_others) in_tuple_typ ;
  List.iteri (fun i expr ->
      Printf.fprintf oc "%s\n\t\t%a"
        (if i > 0 then "," else "")
        (emit_expr ~finalize:true ~state:true) expr ;
    ) exprs ;
  Printf.fprintf oc "\n\t)\n"

let emit_top name in_tuple_typ mentioned and_all_others oc top =
  Printf.fprintf oc "let %s = " name ;
  match top with
  | None -> Printf.fprintf oc "None\n"
  | Some (n, by) ->
    Printf.fprintf oc
      "Some (\n\
       \t(Uint32.to_int (%a)),\n\
       \t(fun %a -> %a))\n"
      (conv_to ~finalize:true ~state:true (Some TU32)) n
      (emit_in_tuple mentioned and_all_others) in_tuple_typ
      (conv_to ~finalize:true ~state:true (Some TFloat)) by

let emit_yield oc in_tuple_typ out_tuple_typ selected_fields =
  let mentioned =
    let all_exprs = List.map (fun sf -> sf.Operation.expr) selected_fields in
    add_all_mentioned_in_expr all_exprs in
  Printf.fprintf oc "open Stdint\n\n\
    %a\n%a\n%a\n\
    let () =\n\
      \tLwt_main.run (\n\
      \t\tCodeGenLib.yield sersize_of_tuple_ serialize_tuple_ select_)\n"
    (emit_field_selection "select_" in_tuple_typ mentioned false out_tuple_typ) selected_fields
    (emit_sersize_of_tuple "sersize_of_tuple_") out_tuple_typ
    (emit_serialize_tuple "serialize_tuple_") out_tuple_typ

let for_each_unpure_fun selected_fields commit_when flush_when f =
  List.iter (fun sf ->
      Expr.unpure_iter f sf.Operation.expr
    ) selected_fields ;
  Expr.unpure_iter f commit_when ;
  Option.may (fun flush_when -> Expr.unpure_iter f flush_when) flush_when

let emit_group_state_init
      name in_tuple_typ mentioned and_all_others
      commit_when flush_when oc selected_fields =
  (* We must collect all unpure functions present in the selected_fields
   * and return a record with the proper types and init values for the required
   * states. And we must do this in a depth first fashion, since a function
   * state might require the value of another function, which must thus
   * already be initialized and ready to fire its first value. *)
  (* In the special case where we do not have any state at all, though, we
   * end up with an empty record, which is illegal in OCaml so we need to
   * specialize for this: *)
  let need_group_state =
    try
      for_each_unpure_fun selected_fields commit_when flush_when (fun _ ->
        raise Exit) ;
      false
    with Exit -> true in
  if not need_group_state then (
    Printf.fprintf oc "type %s = unit\n" name ;
    Printf.fprintf oc "let %s %a = ()\n\n"
      name
      (emit_in_tuple mentioned and_all_others) in_tuple_typ
  ) else (
    (* First emit the record type definition: *)
    Printf.fprintf oc "type %s = {\n" name ;
    for_each_unpure_fun selected_fields commit_when flush_when (fun f ->
        Printf.fprintf oc "\tmutable %s : %s ;\n"
          (name_of_state f)
          (otype_of_state f)
      ) ;
    Printf.fprintf oc "}\n\n" ;
    (* Then the initialization function proper: *)
    Printf.fprintf oc "let %s %a =\n"
      name
      (emit_in_tuple mentioned and_all_others) in_tuple_typ ;
    for_each_unpure_fun selected_fields commit_when flush_when (fun f ->
        Printf.fprintf oc "\tlet %s = " (name_of_state f) ;
        (* For most stateful function we start with the first value.
         * Beware, though, that should we need to evaluate an expression
         * requiring the state record then we should emit the field name
         * only (that has been defined above since we define them in depth
         * first order). *)
        (let open Expr in
        match f with
        | AggrMin (_, e) | AggrMax (_, e) | AggrAnd (_, e)
        | AggrOr (_, e) | AggrFirst (_, e) | AggrLast (_, e)
        | AggrSum (_, e) | ExpSmooth (_, _, e) ->
          (* Start with the initial value, so NULL are propagated naturally *)
          let _impl, arg_typ = implementation_of f in
          conv_to ~finalize:true ~state:false arg_typ oc e
        | AggrPercentile (_, p, e) ->
          (* Have to cater for NULLs *)
          let impl, arg_typ = implementation_of f in
          Printf.fprintf oc
            (if is_nullable e then
              "Option.map (fun e_ -> %s [] %a e_) %a"
            else
              "%s [] %a %a")
            impl
            (conv_to ~finalize:true ~state:false arg_typ) p
            (conv_to ~finalize:true ~state:false arg_typ) e
        | Lag (_, k, e) ->
          let _impl, arg_typ = implementation_of f in
          Printf.fprintf oc
            (if is_nullable e then
              "Option.map (fun e_ -> CodeGenLib.Seasonal.init (Uint16.to_int %a) 1 e_) %a"
            else
              "CodeGenLib.Seasonal.init (Uint16.to_int %a) 1 %a")
            (conv_to ~finalize:true ~state:false (Some TU16)) k
            (conv_to ~finalize:true ~state:false arg_typ) e
        | MovingAvg (_, p, n, e) | LinReg (_, p, n, e) ->
          let _impl, arg_typ = implementation_of f in
          Printf.fprintf oc
            (if is_nullable e then
              "Option.map (fun e_ -> CodeGenLib.Seasonal.init (Uint16.to_int %a) \
                                                              (Uint16.to_int %a) e_) %a"
             else
              "CodeGenLib.Seasonal.init (Uint16.to_int %a) \
                                        (Uint16.to_int %a) %a")
            (conv_to ~finalize:true ~state:false (Some TU16)) p
            (conv_to ~finalize:true ~state:false (Some TU16)) n
            (conv_to ~finalize:true ~state:false arg_typ) e
        | Const _ | Param _ | Field _ | Age _ | Not _ | Defined _ | Concat _
        | Add _ | Sub _ | Mul _ | Div _ | IDiv _ | Pow _ | And _ | Or _ | Ge _
        | Gt _ | Eq _ | Sequence _ | Mod _ | Cast _ | Abs _ | Length _ | Now _
        | BeginOfRange _ | EndOfRange _ | Exp _ | Log _ | Sqrt _ | Split _ ->
          assert false) ;
        Printf.fprintf oc " in\n"
      ) ;
    (* And now build the state record from all those fields: *)
    Printf.fprintf oc "\t{" ;
    for_each_unpure_fun selected_fields commit_when flush_when (fun f ->
        Printf.fprintf oc " %s ;" (name_of_state f)) ;
    Printf.fprintf oc " }\n"
  )

let emit_update_state
      name in_tuple_typ mentioned and_all_others
      commit_when flush_when oc selected_fields =
  Printf.fprintf oc "let %s aggr_ %a =\n"
    name
    (emit_in_tuple mentioned and_all_others) in_tuple_typ ;
  (* Note that for_each_unpure_fun proceed depth first so inner functions
   * state will be updated first, which is what we want. *)
  for_each_unpure_fun selected_fields commit_when flush_when (fun f ->
      Printf.fprintf oc "\taggr_.%s <- (" (name_of_state f) ;
      (let open Expr in
      match f with
      | AggrMin (_, e) | AggrMax (_, e) | AggrSum (_, e) | AggrAnd (_, e)
      | AggrOr (_, e) | AggrFirst (_, e) | AggrLast (_, e)  ->
        (* Note: emit_function2 with use emit_expr to emit "f" here, which
         * will then print it as "aggr_". It will also take care of nulls. *)
        emit_function2 ~finalize:false ~state:true f oc f e
      | AggrPercentile (_, e1, e2) | ExpSmooth (_, e1, e2) ->
        emit_function3 ~finalize:false ~state:true f oc f e1 e2
      | Lag (_, _, e) | MovingAvg (_, _, _, e) | LinReg (_, _, _, e) ->
        emit_function2 ~finalize:false ~state:true f oc f e
      | Const _ | Param _ | Field _ | Age _ | Not _ | Defined _
      | Add _ | Sub _ | Mul _ | Div _ | IDiv _ | Pow _ | And _ | Or _ | Ge _
      | Gt _ | Eq _ | Sequence _ | Mod _ | Cast _ | Abs _ | Length _ | Now _
      | BeginOfRange _ | EndOfRange _ | Exp _ | Log _ | Split _ | Concat _
      | Sqrt _ ->
        assert false) ;
      Printf.fprintf oc ") ;\n"
    ) ;
  Printf.fprintf oc "\t()\n"

(* Note: we need aggr_ in addition to out_tupple because the commit-when clause
 * might have its own stateful functions going on *)
let emit_when name in_tuple_typ mentioned and_all_others out_tuple_typ
              oc commit_when =
  Printf.fprintf oc "let %s virtual_in_count_ %a %a \
                       virtual_selected_count_ virtual_selected_successive_ %a \
                       virtual_unselected_count_ virtual_unselected_successive_ %a \
                       virtual_out_count \
                       %a virtual_group_count_ virtual_group_successive_ aggr_ %a %a \
                       %a =\n\t%a\n"
    name
    (emit_in_tuple mentioned and_all_others) in_tuple_typ
    (emit_in_tuple ~tuple:TupleLastIn mentioned and_all_others) in_tuple_typ
    (emit_in_tuple ~tuple:TupleLastSelected mentioned and_all_others) in_tuple_typ
    (emit_in_tuple ~tuple:TupleLastUnselected mentioned and_all_others) in_tuple_typ
    (emit_tuple TupleGroupPrevious) out_tuple_typ
    (emit_in_tuple ~tuple:TupleGroupFirst mentioned and_all_others) in_tuple_typ
    (emit_in_tuple ~tuple:TupleGroupLast mentioned and_all_others) in_tuple_typ
    (emit_tuple TupleOut) out_tuple_typ
    (emit_expr ~finalize:true ~state:true) commit_when

let emit_should_resubmit name in_tuple_typ mentioned and_all_others
                         oc flush_how =
  let open Operation in
  Printf.fprintf oc "let %s group_state_ %a =\n"
    name
    (emit_in_tuple mentioned and_all_others) in_tuple_typ ;
  match flush_how with
  | Reset ->
    Printf.fprintf oc "\tfalse\n"
  | Slide n ->
    Printf.fprintf oc "\tgroup_state_.CodeGenLib.nb_entries > %d\n" n
  | KeepOnly e ->
    Printf.fprintf oc "\t%a\n" (emit_expr ~finalize:true ~state:true) e
  | RemoveAll e ->
    Printf.fprintf oc "\tnot (%a)\n" (emit_expr ~finalize:true ~state:true) e

(* Depending on what uses a commit/flush condition, we might need to check
 * all groups after every single input tuple (very slow), or after every
 * selected input tuple (still quite slow), or only when this group is
 * modified (fast). Users should limit all/selected tuple to aggregations
 * with few groups only. *)
let when_to_check_group_for_expr expr =
  (* Tells whether the commit condition needs the all or the selected tuple *)
  let open Expr in
  let need_all, need_selected =
    fold_by_depth (fun (need_all, need_selected) -> function
        | Field (_, tuple, _) ->
          (need_all || !tuple = TupleIn || !tuple = TupleLastIn),
          (need_selected || !tuple = TupleLastSelected || !tuple = TupleSelected
                         || !tuple = TupleLastUnselected || !tuple = TupleUnselected)
        | _ ->
          need_all, need_selected
      ) (false, false) expr
  in
  if need_all then "CodeGenLib.ForAll" else
  if need_selected then "CodeGenLib.ForAllSelected" else
  "CodeGenLib.ForAllInGroup"

let emit_aggregate oc in_tuple_typ out_tuple_typ
                   selected_fields and_all_others where key top
                   commit_when flush_when flush_how notify_url =
(* We need:
 * - as above: a where filter, a serializer,
 * - a function computing the key as a tuple computed from input, exactly as in
 *   a select,
 * - a function of in and out and others and any, that returns true when we
 *   must emit the out tuple
 * - contrary to select, the selected fields are not used to build a function
 *   returning tuple out given tuple in. Here, the select fields are used to
 *   build 2 things:
 *   - a function that returns tuple out init (a mutable record!) from a tuple
 *     in
 *   - a function that update tuple out (record) given a tuple in
 *   We cannot generate less code than that if we want to use a record for
 *   tuple out.
 * With all this CodeGenLib will easily implement a basic version of aggregate
 * and could also implement more sophisticated versions.
 *
 * Note: some aggregation function value cannot be computed in the update.
 * For instance, percentile accumulates all encountered values into a list
 * and must then, at the end, sort that list and return only the requested
 * percentile. That is why when we read the aggr_ record we do not get
 * the value directly but uses a function specific to the aggregation
 * function (which often reduces to identity). *)
  let mentioned =
    let all_exprs =
      where :: commit_when :: key @
      List.map (fun sf -> sf.Operation.expr) selected_fields in
    let all_exprs = match flush_when with
      | None -> all_exprs
      | Some flush_when -> flush_when :: all_exprs in
    let all_exprs =
      let open Operation in
      match flush_how with
      | Reset | Slide _ -> all_exprs
      | RemoveAll e | KeepOnly e -> e :: all_exprs in
    add_all_mentioned_in_expr all_exprs
  and where_need_state =
    (* Tells whether the where expression needs a tuple that's only
     * available once we have retrieved the key and the group (because
     * it uses the group tuple or build an aggregation on its own): *)
    let open Expr in
    fold_by_depth (fun need expr ->
      need || match expr with
        | Field (_, tuple, _) -> tuple_need_state !tuple
        | AggrMin _| AggrMax _| AggrSum _| AggrAnd _
        | AggrOr _| AggrFirst _| AggrLast _| AggrPercentile _ | Lag _
        | MovingAvg _ | LinReg _ | ExpSmooth _ ->
          true
        | Age _| Sequence _| Not _| Defined _| Add _| Sub _| Mul _| Div _
        | IDiv _| Pow _| And _| Or _| Ge _| Gt _| Eq _| Const _| Param _
        | Mod _| Cast _ | Abs _ | Length _ | Now _ | BeginOfRange _
        | EndOfRange _ | Exp _ | Log _ | Sqrt _ | Split _ | Concat _ ->
          false
      ) false where
  and when_to_check_for_commit = when_to_check_group_for_expr commit_when in
  let when_to_check_for_flush =
    match flush_when with
    | None -> when_to_check_for_commit
    | Some flush_when -> when_to_check_group_for_expr flush_when
  in
  Printf.fprintf oc "open Stdint\n\n\
    %a\n%a\n%a\n%a\n%a\n%a\n%a\n%a\n%a\n%a\n%a\n%a\n%a\n%a\n"
    (emit_group_state_init "aggr_init_" in_tuple_typ mentioned and_all_others commit_when flush_when) selected_fields
    (emit_read_tuple "read_tuple_" mentioned and_all_others) in_tuple_typ
    (if where_need_state then
      emit_where "where_fast_" ~always_true:true in_tuple_typ mentioned and_all_others
    else
      emit_where "where_fast_" in_tuple_typ mentioned and_all_others) where
    (if not where_need_state then
      emit_where "where_slow_" ~with_group:true ~always_true:true in_tuple_typ mentioned and_all_others
    else
      emit_where "where_slow_" ~with_group:true in_tuple_typ mentioned and_all_others) where
    (emit_key_of_input "key_of_input_" in_tuple_typ mentioned and_all_others) key
    (emit_update_state "update_aggr_" in_tuple_typ mentioned and_all_others commit_when flush_when) selected_fields
    (emit_when "commit_when_" in_tuple_typ mentioned and_all_others out_tuple_typ) commit_when
    (emit_field_selection ~with_selected:true ~with_group:true "tuple_of_aggr_" in_tuple_typ mentioned and_all_others out_tuple_typ) selected_fields
    (emit_sersize_of_tuple "sersize_of_tuple_") out_tuple_typ
    (emit_serialize_tuple "serialize_aggr_") out_tuple_typ
    (emit_generate_tuples "generate_tuples_" in_tuple_typ mentioned and_all_others out_tuple_typ) selected_fields
    (emit_should_resubmit "should_resubmit_" in_tuple_typ mentioned and_all_others) flush_how
    (emit_field_of_tuple "field_of_tuple_" mentioned and_all_others) in_tuple_typ
    (emit_top "top_" in_tuple_typ mentioned and_all_others) top ;
  (match flush_when with
  | Some flush_when ->
    emit_when "flush_when_" in_tuple_typ mentioned and_all_others out_tuple_typ oc flush_when
  | None ->
    Printf.fprintf oc "let flush_when_ = commit_when_\n") ;
  Printf.fprintf oc "let () =\n\
      \tLwt_main.run (\n\
      \t\tCodeGenLib.aggregate \
           read_tuple_ sersize_of_tuple_ serialize_aggr_ generate_tuples_ \
           tuple_of_aggr_ where_fast_ where_slow_ key_of_input_ top_ \
           commit_when_ %s flush_when_ %s \
           should_resubmit_ aggr_init_ update_aggr_ \
           field_of_tuple_ %S)\n"
    when_to_check_for_commit when_to_check_for_flush notify_url

let sanitize_ocaml_fname s =
  let open Str in
  let replace_by_underscore _ = "_"
  and re = regexp "[^A-Za-z0-9_]" in
  (* Must start with a letter: *)
  "m"^ global_substitute re replace_by_underscore s

let with_code_file_for exec_name conf f =
  let fname =
    conf.C.persist_dir ^"/src/ocaml/m"^ (Filename.basename exec_name) ^".ml" in
  mkdir_all ~is_file:true fname ;
  if file_exists ~maybe_empty:false fname then
    !logger.debug "Reusing source file %S" fname
  else
    File.with_file_out ~mode:[`create; `text] fname f ;
  fname

let compile_source exec_name fname =
  Printf.sprintf
    "nice ocamlfind ocamlopt -g -annot -o %s \
      -package batteries,stdint,lwt.ppx,cohttp-lwt-unix,inotify.lwt,binocle,parsercombinator \
      -linkpkg codegen.cmxa %s"
    (shell_quote exec_name)
    (shell_quote fname)

let gen_operation conf exec_name in_tuple_typ out_tuple_typ op =
  let open Operation in
  with_code_file_for exec_name conf (fun oc ->
    (match op with
    | Yield fields ->
      emit_yield oc in_tuple_typ out_tuple_typ fields
    | ReadCSVFile { fname ; unlink ; separator ; null ; fields ; preprocessor } ->
      emit_read_csv_file oc fname unlink separator null fields preprocessor
    | Aggregate { fields ; and_all_others ; where ; key ; top ; commit_when ;
                  flush_when ; flush_how ; notify_url ; _ } ->
      emit_aggregate oc in_tuple_typ out_tuple_typ fields and_all_others where
                     key top commit_when flush_when flush_how notify_url)) |>
    compile_source exec_name
