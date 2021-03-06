(* This module parses operations (and offer a few utilities related to
 * operations).
 * An operation is what will result in running workers later.
 * The main operation is the `SELECT / GROUP BY` operation, but there a
 * few others of lesser importance.
 *
 * Operations are made of expressions, parsed in RamenExpr.
 *)
open Batteries
open RamenLang
open RamenHelpers
open RamenLog
module Expr = RamenExpr

(*$inject
  open TestHelpers
  open RamenLang
*)

(* Direct field selection (not for group-bys) *)
type selected_field = { expr : Expr.t ; alias : string }

let print_selected_field fmt f =
  let need_alias =
    match f.expr with
    | Expr.Field (_, tuple, field)
      when !tuple = TupleIn && f.alias = field -> false
    | _ -> true in
  if need_alias then
    Printf.fprintf fmt "%a AS %s"
      (Expr.print false) f.expr
      f.alias
  else
    Expr.print false fmt f.expr

type flush_method = Reset | Slide of int
                  | KeepOnly of Expr.t | RemoveAll of Expr.t
                  | Never

let print_flush_method oc = function
  | Reset ->
    Printf.fprintf oc "FLUSH"
  | Never ->
    Printf.fprintf oc "KEEP ALL"
  | Slide n ->
    Printf.fprintf oc "SLIDE %d" n
  | KeepOnly e ->
    Printf.fprintf oc "KEEP (%a)" (Expr.print false) e
  | RemoveAll e ->
    Printf.fprintf oc "REMOVE (%a)" (Expr.print false) e

type file_spec = { fname : string ; unlink : bool }
type csv_specs =
  { separator : string ; null : string ; fields : RamenTuple.typ }

(* Type of notifications. As those are transmitted in a single text field we
 * convert them using PPP. We could as well use Marshal but PPP is friendlier
 * to `ramen tail`. We could also use the ramen language syntax but parsing
 * it again from the notifier looks wasteful. *)

type http_cmd_method = HttpCmdGet | HttpCmdPost
  [@@ppp PPP_OCaml]

type http_cmd =
  { method_ : http_cmd_method
      [@ppp_rename "method"] [@ppp_default HttpCmdGet] ;
    url : string ;
    headers : (string * string) list
      [@ppp_default []] ;
    body : string [@ppp_default ""] }
  [@@ppp PPP_OCaml]

type severity = Urgent | Deferrable
  [@@ppp PPP_OCaml]

type notify_cmd =
  { name : string ;
    severity : severity
      [@ppp_default Urgent] ;
    parameters : (string * string) list
      [@ppp_default []] }
  [@@ppp PPP_OCaml]

type notification =
  | ExecuteCmd of string
  | HttpCmd of http_cmd
  | SysLog of string
  | NotifyCmd of notify_cmd
  [@@ppp PPP_OCaml]

let print_notification oc = function
  | ExecuteCmd cmd ->
      Printf.fprintf oc "EXECUTE %S" cmd
  | HttpCmd http ->
      Printf.fprintf oc "HTTP%s TO %S"
        (match http.method_ with HttpCmdGet -> "" | HttpCmdPost -> " POST")
        http.url ;
      if http.headers <> [] then
        List.print ~first:" WITH HEADERS " ~last:"" ~sep:", "
          (fun oc (n, v) -> Printf.fprintf oc "%S:%S" n v) oc http.headers ;
      if http.body <> "" then
        Printf.fprintf oc " WITH BODY %S" http.body
  | SysLog str ->
      Printf.fprintf oc "LOGGER %S" str
  | NotifyCmd notif ->
      Printf.fprintf oc "NOTIFY %S %s"
        notif.name
        (match notif.severity with
         | Urgent -> "URGENT"
         | Deferrable -> "DEFERRABLE") ;
      if notif.parameters <> [] then
        List.print ~first:" WITH PARAMETERS " ~last:"" ~sep:", "
          (fun oc (n, v) -> Printf.fprintf oc "%S=%S" n v) oc
          notif.parameters

(* Type of an operation: *)

type t =
  (* Aggregation of several tuples into one based on some key. Superficially looks like
   * a select but much more involved. *)
  | Aggregate of {
      fields : selected_field list ;
      (* Pass all fields not used to build an aggregated field *)
      and_all_others : bool ;
      merge : Expr.t list * float (* timeout *) ;
      sort : (int * Expr.t option (* until *) * Expr.t list (* by *)) option ;
      (* Simple way to filter out incoming tuples: *)
      where : Expr.t ;
      event_time : RamenEventTime.t option ;
      force_export : bool ;
      (* Will send these notification commands to the notifier: *)
      notifications : notification list ;
      key : Expr.t list ;
      top : (Expr.t (* N *) * Expr.t (* by *)) option ;
      commit_when : Expr.t ;
      commit_before : bool ; (* commit first and aggregate later *)
      (* How to flush: reset or slide values *)
      flush_how : flush_method ;
      (* List of funcs that are our parents *)
      from : string list ;
      every : float ;
      factors : string list }
  | ReadCSVFile of {
      where : file_spec ;
      what : csv_specs ;
      preprocessor : string ;
      event_time : RamenEventTime.t option ;
      force_export : bool ;
      factors : string list }
  | ListenFor of {
      net_addr : Unix.inet_addr ;
      port : int ;
      proto : RamenProtocols.net_protocol ;
      force_export : bool ;
      factors : string list }
  | Instrumentation of {
      from : string list ;
      force_export : bool
      (* factors are hardcoded *) }

let print_csv_specs fmt specs =
  Printf.fprintf fmt "SEPARATOR %S NULL %S %a"
    specs.separator specs.null
    RamenTuple.print_typ specs.fields
let print_file_spec fmt specs =
  Printf.fprintf fmt "READ%s FILES %S"
    (if specs.unlink then " AND DELETE" else "") specs.fname

let print fmt =
  let sep = ", " in
  let print_single_quoted oc s = Printf.fprintf oc "'%s'" s in
  let print_export fmt event_time force_export =
    Option.may (fun e ->
      Printf.fprintf fmt " %a" RamenEventTime.print e
    ) event_time ;
    if force_export then Printf.fprintf fmt " EXPORT" in
  function
  | Aggregate { fields ; and_all_others ; merge ; sort ; where ; event_time ;
                force_export ; notifications ; key ; top ; commit_when ;
                commit_before ; flush_how ; from ; every } ->
    if from <> [] then
      List.print ~first:"FROM " ~last:"" ~sep print_single_quoted fmt from ;
    if fst merge <> [] then (
      Printf.fprintf fmt " MERGE ON %a"
        (List.print ~first:"" ~last:"" ~sep:", " (Expr.print false)) (fst merge) ;
      if snd merge > 0. then
        Printf.fprintf fmt " TIMEOUT AFTER %g SECONDS" (snd merge)) ;
    Option.may (fun (n, u_opt, b) ->
      Printf.fprintf fmt " SORT LAST %d" n ;
      Option.may (fun u ->
        Printf.fprintf fmt " OR UNTIL %a"
          (Expr.print false) u) u_opt ;
      Printf.fprintf fmt " BY %a"
        (List.print ~first:"" ~last:"" ~sep:", " (Expr.print false)) b
    ) sort ;
    if fields <> [] || not and_all_others then
      Printf.fprintf fmt " SELECT %a%s%s"
        (List.print ~first:"" ~last:"" ~sep print_selected_field) fields
        (if fields <> [] && and_all_others then sep else "")
        (if and_all_others then "*" else "") ;
    if every > 0. then
      Printf.fprintf fmt " EVERY %g SECONDS" every ;
    if not (Expr.is_true where) then
      Printf.fprintf fmt " WHERE %a"
        (Expr.print false) where ;
    print_export fmt event_time force_export ;
    if key <> [] then
      Printf.fprintf fmt " GROUP BY %a"
        (List.print ~first:"" ~last:"" ~sep:", " (Expr.print false)) key ;
    Option.may (fun (n, by) ->
      Printf.fprintf fmt " TOP %a BY %a"
        (Expr.print false) n
        (Expr.print false) by) top ;
    if not (Expr.is_true commit_when) ||
       flush_how <> Reset ||
       notifications <> [] then (
      let sep = ref " " in
      if flush_how = Reset && notifications = [] then (
        Printf.fprintf fmt "%sCOMMIT" !sep ; sep := ", ") ;
      if flush_how <> Reset then (
        Printf.fprintf fmt "%s%a" !sep print_flush_method flush_how ;
        sep := ", ") ;
      if notifications <> [] then (
        List.print ~first:!sep ~last:"" ~sep:!sep print_notification
          fmt notifications ;
        sep := ", ") ;
      if not (Expr.is_true commit_when) then
        Printf.fprintf fmt " %s %a"
          (if commit_before then "BEFORE" else "AFTER")
          (Expr.print false) commit_when)
  | ReadCSVFile { where = file_spec ;
                  what = csv_specs ; preprocessor ; event_time ;
                  force_export } ->
    Printf.fprintf fmt "%a %s %a"
      print_file_spec file_spec
      (if preprocessor = "" then ""
        else Printf.sprintf "PREPROCESS WITH %S" preprocessor)
      print_csv_specs csv_specs ;
    print_export fmt event_time force_export ;
  | ListenFor { net_addr ; port ; proto ; force_export } ->
    Printf.fprintf fmt "LISTEN FOR %s ON %s:%d"
      (RamenProtocols.string_of_proto proto)
      (Unix.string_of_inet_addr net_addr)
      port ;
    print_export fmt None force_export
  | Instrumentation { from ; force_export } ->
    Printf.fprintf fmt "LISTEN FOR INSTRUMENTATION%a"
      (List.print ~first:" FROM " ~last:"" ~sep:", "
         print_single_quoted) from ;
    print_export fmt None force_export

let is_exporting = function
  | Aggregate { force_export ; _ }
  | ListenFor { force_export ; _ }
  | ReadCSVFile { force_export ; _ }
  | Instrumentation { force_export ; _ } ->
    force_export (* FIXME: this info should come from the func *)

let is_merging = function
  | Aggregate { merge ; _ } when fst merge <> [] -> true
  | _ -> false

let event_time_of_operation = function
  | Aggregate { event_time ; _ } -> event_time
  | ReadCSVFile { event_time ; _ } -> event_time
  | ListenFor { proto ; _ } ->
    RamenProtocols.event_time_of_proto proto
  | Instrumentation _ -> RamenBinocle.event_time

let parents_of_operation = function
  | ListenFor _ | ReadCSVFile _
  (* Note that instrumentation has a from clause but no actual parents: *)
  | Instrumentation _ -> []
  | Aggregate { from ; _ } -> from

let factors_of_operation = function
  | ReadCSVFile { factors ; _ }
  | Aggregate { factors ; _ } -> factors
  | ListenFor { factors ; proto ; _ } ->
    if factors <> [] then factors
    else RamenProtocols.factors_of_proto proto
  | Instrumentation _ -> RamenBinocle.factors

let fold_expr init f = function
  | ListenFor _ | ReadCSVFile _ | Instrumentation _ -> init
  | Aggregate { fields ; merge ; sort ; where ; key ; top ; commit_when ;
                flush_how ; _ } ->
      let x =
        List.fold_left (fun prev sf ->
            Expr.fold_by_depth f prev sf.expr
          ) init fields in
      let x = List.fold_left (fun prev me ->
            Expr.fold_by_depth f prev me
          ) x (fst merge) in
      let x = Expr.fold_by_depth f x where in
      let x = List.fold_left (fun prev ke ->
            Expr.fold_by_depth f prev ke
          ) x key in
      let x = Option.map_default (fun (n, by) ->
          let x = Expr.fold_by_depth f x n in
          Expr.fold_by_depth f x by
        ) x top in
      let x = Expr.fold_by_depth f x commit_when in
      let x = match sort with
        | None -> x
        | Some (_, u_opt, b) ->
            let x = match u_opt with
              | None -> x
              | Some u -> Expr.fold_by_depth f x u in
            List.fold_left (fun prev e ->
              Expr.fold_by_depth f prev e
            ) x b in
      match flush_how with
      | Slide _ | Never | Reset -> x
      | RemoveAll e | KeepOnly e ->
        Expr.fold_by_depth f x e

let iter_expr f op =
  fold_expr () (fun () e -> f e) op

(* Check that the expression is valid, or return an error message.
 * Also perform some optimisation, numeric promotions, etc...
 * This is done after the parse rather than Rejecting the parsing
 * result for better error messages, and also because we need the
 * list of available parameters. *)
let check params =
  let pure_in clause = StatefulNotAllowed { clause }
  and no_group clause = StateNotAllowed { state = "local" ; clause }
  and no_global clause = StateNotAllowed { state = "global" ; clause }
  and fields_must_be_from tuple where allowed =
    TupleNotAllowed { tuple ; where ; allowed } in
  let pure_in_key = pure_in "GROUP-BY"
  and check_pure e =
    Expr.unpure_iter (fun _ -> raise (SyntaxError e))
  and check_no_state state e =
    Expr.unpure_iter (function
      | StatefulFun (_, s, _) when s = state -> raise (SyntaxError e)
      | _ -> ())
  and check_no_both_states e x =
    Expr.unpure_fold None (fun prev -> function
      | StatefulFun (_, s, _) ->
          if prev = Some s then raise (SyntaxError e) ;
          Some s
      | _ -> prev) x |> ignore
  and check_fields_from lst where =
    Expr.iter (function
      | Expr.Field (_, tuple, _) ->
        if not (List.mem !tuple lst) then (
          let m = fields_must_be_from !tuple where lst in
          raise (SyntaxError m)
        )
      | _ -> ())
  and check_field_exists fields f =
    if not (List.exists (fun sf -> sf.alias = f) fields) then
      let m =
        let print_alias oc sf = String.print oc sf.alias in
        let tuple_type = IO.to_string (List.print print_alias) fields in
        FieldNotInTuple { field = f ; tuple = TupleOut ; tuple_type } in
      raise (SyntaxError m) in
  let check_no_group = check_no_state LocalState
  and check_no_global = check_no_state GlobalState
  in
  let check_event_time fields ((start_field, _), duration) =
    check_field_exists fields start_field ;
    match duration with
    | RamenEventTime.DurationConst _ -> ()
    | RamenEventTime.DurationField (f, _)
    | RamenEventTime.StopField (f, _) -> check_field_exists fields f
  and check_factors fields = List.iter (check_field_exists fields)
  (* Unless it's a param, assume TupleUnknow belongs to def: *)
  and prefix_def def =
    Expr.iter (function
      | Field (_, ({ contents = TupleUnknown } as pref), alias) ->
          if List.mem_assoc alias params then
            pref := TupleParam
          else
            pref := def
      | _ -> ())
  in
  function
  | Aggregate { fields ; and_all_others ; merge ; sort ; where ; key ; top ;
                commit_when ; flush_how ; event_time ;
                from ; every ; factors } as op ->
    (* Set of fields known to come from in (to help prefix_smart): *)
    let fields_from_in = ref Set.empty in
    iter_expr (function
      | Field (_, { contents = (TupleIn|TupleLastIn|TupleSelected|
                                TupleLastSelected|TupleUnselected|
                                TupleLastUnselected) }, alias) ->
          fields_from_in := Set.add alias !fields_from_in
      | _ -> ()) op ;
    let is_selected_fields ?i alias = (* Tells if a field is in _out_ *)
      list_existsi (fun i' sf ->
        sf.alias = alias &&
        Option.map_default (fun i -> i' < i) true i) fields in
    (* Resolve TupleUnknown into either TupleParam (if the alias is in
     * params), TupleIn or TupleOut (depending on the presence of this alias
     * in selected_fields -- optionally, only before position i) *)
    let prefix_smart ?i =
      Expr.iter (function
        | Field (_, ({ contents = TupleUnknown } as pref), alias) ->
            if List.mem_assoc alias params then
              pref := TupleParam
            else if Set.mem alias !fields_from_in then
              pref := TupleIn
            else if is_selected_fields ?i alias then
              pref := TupleOut
            else (
              pref := TupleIn ;
              fields_from_in := Set.add alias !fields_from_in) ;
            !logger.debug "Field %S thought to belong to %s"
              alias (string_of_prefix !pref)
        | _ -> ()) in
    List.iteri (fun i sf -> prefix_smart ~i sf.expr) fields ;
    List.iter (prefix_def TupleIn) (fst merge) ;
    Option.may (fun (_, u_opt, b) ->
      List.iter (prefix_def TupleIn) b ;
      Option.may (prefix_def TupleIn) u_opt) sort ;
    prefix_smart where ;
    List.iter (prefix_def TupleIn) key ;
    Option.may (fun (n, by) ->
      prefix_smart n ; prefix_def TupleIn by) top ;
    prefix_smart commit_when ;
    (match flush_how with
    | KeepOnly e | RemoveAll e -> prefix_def TupleGroup e
    | _ -> ()) ;
    (* Check that we use the TupleGroup only for virtual fields: *)
    iter_expr (function
      | Field (_, { contents = TupleGroup }, alias) ->
        if not (is_virtual_field alias) then
          raise (SyntaxError (TupleHasOnlyVirtuals { tuple = TupleGroup ;
                                                     alias }))
      | _ -> ()) op ;
    (* Now check what tuple prefix are used: *)
    List.fold_left (fun prev_aliases sf ->
        check_fields_from [TupleParam; TupleLastIn; TupleIn; TupleGroup; TupleSelected; TupleLastSelected; TupleUnselected; TupleLastUnselected; TupleGroupFirst; TupleGroupLast; TupleOut (* FIXME: only if defined earlier *); TupleGroupPrevious; TupleOutPrevious] "SELECT clause" sf.expr ;
        (* Check unicity of aliases *)
        if List.mem sf.alias prev_aliases then
          raise (SyntaxError (AliasNotUnique sf.alias)) ;
        sf.alias :: prev_aliases
      ) [] fields |> ignore;
    if not and_all_others then (
      Option.may (check_event_time fields) event_time ;
      check_factors fields factors
    ) ;
    (* Disallow group state in WHERE because it makes no sense: *)
    check_no_group (no_group "WHERE") where ;
    check_fields_from [TupleParam; TupleLastIn; TupleIn; TupleSelected; TupleLastSelected; TupleUnselected; TupleLastUnselected; TupleGroup; TupleGroupFirst; TupleGroupLast; TupleOutPrevious] "WHERE clause" where ;
    List.iter (fun k ->
      check_pure pure_in_key k ;
      check_fields_from [TupleParam; TupleIn] "Group-By KEY" k) key ;
    Option.may (fun (n, by) ->
      (* TODO: Check also that it's an unsigned integer: *)
      Expr.check_const "TOP size" n ;
      (* Also check that the top-by expression does not update the global
       * state: *)
      check_no_global (no_global "TOP-BY") by ;
      (* Also check that commit_when does not use both the group and global
       * state, as we won't be able to update the global state when in
       * tuple ends up in "others" if commit-when needs the group: *)
      let e = StateNotAllowed {
        state = "global and local" ; clause = "COMMIT-WHEN (with TOP)" } in
      check_no_both_states e commit_when ;
      check_fields_from [TupleParam; TupleLastIn; TupleIn; TupleGroup; TupleSelected; TupleLastSelected; TupleUnselected; TupleLastUnselected; TupleGroupFirst; TupleGroupLast; TupleOut; TupleGroupPrevious; TupleOutPrevious] "TOP clause" by ;
      (* The only windowing mode supported is then `commit and flush`: *)
      if flush_how <> Reset then
        raise (SyntaxError OnlyTumblingWindowForTop)
    ) top ;
    check_fields_from [TupleParam; TupleLastIn; TupleIn; TupleSelected; TupleLastSelected; TupleUnselected; TupleLastUnselected; TupleOut; TupleGroupPrevious; TupleOutPrevious; TupleGroupFirst; TupleGroupLast; TupleGroup; TupleSelected; TupleLastSelected] "COMMIT WHEN clause" commit_when ;
    (match flush_how with
    | Reset | Never | Slide _ -> ()
    | RemoveAll e | KeepOnly e ->
      let m = StatefulNotAllowed { clause = "KEEP/REMOVE" } in
      check_pure m e ;
      check_fields_from [TupleParam; TupleGroup] "REMOVE clause" e) ;
    if every > 0. && from <> [] then
      raise (SyntaxError (EveryWithFrom)) ;
    (* Check that we do not use any fields from out that is generated: *)
    let generators = List.filter_map (fun sf ->
        if Expr.is_generator sf.expr then Some sf.alias else None
      ) fields in
    iter_expr (function
        | Field (_, tuple_ref, alias)
          when !tuple_ref = TupleOutPrevious ||
               !tuple_ref = TupleGroupPrevious ->
            if List.mem alias generators then
              let e = NoAccessToGeneratedFields { alias } in
              raise (SyntaxError e)
        | _ -> ()) op

    (* TODO: notifications: check field names from text templates *)

  | ReadCSVFile _ -> () (* TODO: check_event_time, check_factors!*)
  | ListenFor _ -> ()
  | Instrumentation _ -> ()

module Parser =
struct
  (*$< Parser *)
  open RamenParsing

  let default_alias =
    let open Expr in
    let force_public field =
      if String.length field = 0 || field.[0] <> '_' then field
      else String.lchop field in
    function
    | Field (_, _, field)
        when not (is_virtual_field field) -> field
    (* Provide some default name for common aggregate functions: *)
    | StatefulFun (_, _, AggrMin (Field (_, _, field))) -> "min_"^ force_public field
    | StatefulFun (_, _, AggrMax (Field (_, _, field))) -> "max_"^ force_public field
    | StatefulFun (_, _, AggrSum (Field (_, _, field))) -> "sum_"^ force_public field
    | StatefulFun (_, _, AggrAvg (Field (_, _, field))) -> "avg_"^ force_public field
    | StatefulFun (_, _, AggrAnd (Field (_, _, field))) -> "and_"^ force_public field
    | StatefulFun (_, _, AggrOr (Field (_, _, field))) -> "or_"^ force_public field
    | StatefulFun (_, _, AggrFirst (Field (_, _, field))) -> "first_"^ force_public field
    | StatefulFun (_, _, AggrLast (Field (_, _, field))) -> "last_"^ force_public field
    | StatefulFun (_, _, AggrPercentile (Const (_, p), Field (_, _, field)))
      when RamenScalar.is_round_integer p ->
      Printf.sprintf "%s_%sth" (force_public field) (IO.to_string RamenScalar.print p)
    | _ -> raise (Reject "must set alias")

  let selected_field m =
    let m = "selected field" :: m in
    (Expr.Parser.p ++ optional ~def:None (
       blanks -- strinG "as" -- blanks -+ some non_keyword) >>:
     fun (expr, alias) ->
      let alias =
        Option.default_delayed (fun () -> default_alias expr) alias in
      { expr ; alias }) m

  let list_sep m =
    let m = "list separator" :: m in
    (opt_blanks -- char ',' -- opt_blanks) m

  let export_clause m =
    let m = "export clause" :: m in
    (strinG "export" >>: fun () -> true) m

  let event_time_clause m =
    let m = "event time clause" :: m in
    let scale m =
      let m = "scale event field" :: m in
      (optional ~def:1. (
        (optional ~def:() blanks -- star --
         optional ~def:() blanks -+ number ))
      ) m
    in (
      strinG "event" -- blanks -- (strinG "starting" ||| strinG "starts") --
      blanks -- strinG "at" -- blanks -+ non_keyword ++ scale ++
      optional ~def:(RamenEventTime.DurationConst 0.) (
        (blanks -- optional ~def:() ((strinG "and" ||| strinG "with") -- blanks) --
         strinG "duration" -- blanks -+ (
           (non_keyword ++ scale >>: fun n -> RamenEventTime.DurationField n) |||
           (duration >>: fun n -> RamenEventTime.DurationConst n)) |||
         blanks -- strinG "and" -- blanks --
         (strinG "stops" ||| strinG "stopping" |||
          strinG "ends" ||| strinG "ending") -- blanks --
         strinG "at" -- blanks -+
           (non_keyword ++ scale >>: fun n -> RamenEventTime.StopField n)))) m

  let every_clause m =
    let m = "every clause" :: m in
    (strinG "every" -- blanks -+ duration >>: fun every ->
       if every < 0. then
         raise (Reject "sleep duration must be greater than 0") ;
       every) m

  let select_clause m =
    let m = "select clause" :: m in
    ((strinG "select" ||| strinG "yield") -- blanks -+
     several ~sep:list_sep
             ((star >>: fun _ -> None) |||
              some selected_field)) m

  let merge_clause m =
    let m = "merge clause" :: m in
    (strinG "merge" -- blanks -- strinG "on" -- blanks -+
     several ~sep:list_sep Expr.Parser.p ++ optional ~def:0. (
       blanks -- strinG "timeout" -- blanks -- strinG "after" -- blanks -+
       duration)) m

  let sort_clause m =
    let m = "sort clause" :: m in
    (strinG "sort" -- blanks -- strinG "last" -- blanks -+
     pos_integer "Sort buffer size" ++
     optional ~def:None (
       blanks -- strinG "or" -- blanks -- strinG "until" -- blanks -+
       some Expr.Parser.p) +- blanks +-
     strinG "by" +- blanks ++ several ~sep:list_sep Expr.Parser.p >>:
      fun ((l, u), b) -> l, u, b) m

  let where_clause m =
    let m = "where clause" :: m in
    ((strinG "where" ||| strinG "when") -- blanks -+ Expr.Parser.p) m

  let group_by m =
    let m = "group-by clause" :: m in
    (strinG "group" -- blanks -- strinG "by" -- blanks -+
     several ~sep:list_sep Expr.Parser.p) m

  let top_clause m =
    let m ="top-by clause" :: m in
    (strinG "top" -- blanks -+ Expr.Parser.p +- blanks +-
     strinG "by" +- blanks ++ Expr.Parser.p +- blanks +-
     strinG "when" +- blanks ++ Expr.Parser.p) m

  type commit_spec =
    | NotifySpec of notification
    | FlushSpec of flush_method
    | CommitSpec (* we would commit anyway, just a placeholder *)

  let list_sep_and =
    (blanks -- strinG "and" -- blanks) |||
    (opt_blanks -- char ',' -- opt_blanks)

  let notification_clause m =
    let execute m =
      let m = "execute clause" :: m in
      (strinG "execute" -- blanks -+ quoted_string >>:
       fun s -> ExecuteCmd s) m in
    let kv_list m =
      let m = "key-value list" :: m in
      (quoted_string +- opt_blanks +- (char ':' ||| char '=') +-
       opt_blanks ++ quoted_string) m in
    let opt_with = optional ~def:() (blanks -- strinG "with") in
    let logger m =
      let m = "logger clause" :: m in
      (strinG "logger" -- blanks -+ quoted_string >>:
       fun s -> SysLog s) m in
    let http_cmd m =
      let m = "http notification" :: m in
      (strinG "http" -+
       optional ~def:HttpCmdGet
         (blanks -+
          (strinG "get" >>: fun () -> HttpCmdGet) |||
          (strinG "post" >>: fun () -> HttpCmdPost)) +-
       blanks ++ quoted_string ++
       optional ~def:[]
         (opt_with -- blanks -- strinGs "header" -- blanks -+
          several ~sep:list_sep_and kv_list) ++
       optional ~def:""
         (opt_with -- blanks -- strinG "body" -- blanks -+
          quoted_string) >>:
       fun (((method_, url), headers), body) ->
        HttpCmd { method_ ; url ; headers ; body }) m in
    let notify_cmd m =
      let severity m =
        let m = "notification severity" :: m in
        ((strinG "urgent" >>: fun () -> Urgent) |||
         (strinG "deferrable" >>: fun () -> Deferrable)) m in
      let m = "notification" :: m in
      (strinG "notify" -- blanks -+ quoted_string ++
       optional ~def:Urgent (blanks -+ severity) ++
       optional ~def:[]
         (opt_with -- blanks -- strinGs "parameter" -- blanks -+
          several ~sep:list_sep_and kv_list) >>:
      fun ((name, severity), parameters) ->
        NotifyCmd { name ; severity ; parameters }) m
    in
    let m = "notification clause" :: m in
    ((execute ||| http_cmd ||| logger ||| notify_cmd) >>:
     fun s -> NotifySpec s) m

  let flush m =
    let m = "flush clause" :: m in
    ((strinG "flush" >>: fun () -> Reset) |||
     (strinG "slide" -- blanks -+ (pos_integer "Sliding amount" >>:
        fun n -> Slide n)) |||
     (strinG "keep" -- blanks -- strinG "all" >>: fun () ->
       Never) |||
     (strinG "keep" -- blanks -+ Expr.Parser.p >>: fun e ->
       KeepOnly e) |||
     (strinG "remove" -- blanks -+ Expr.Parser.p >>: fun e ->
       RemoveAll e) >>:
     fun s -> FlushSpec s) m

  let dummy_commit m =
    (strinG "commit" >>: fun () -> CommitSpec) m

  let default_commit_when = Expr.expr_true

  let commit_clause m =
    let m = "commit clause" :: m in
    (several ~sep:list_sep_and ~what:"commit clauses"
       (dummy_commit ||| notification_clause ||| flush) ++
     optional ~def:(false, default_commit_when)
      (blanks -+
       ((strinG "after" >>: fun _ -> false) |||
        (strinG "before" >>: fun _ -> true)) +- blanks ++
       Expr.Parser.p)) m

  let from_clause m =
    let m = "from clause" :: m in
    (strinG "from" -- blanks -+
     several ~sep:list_sep_and (func_identifier ~globs_allowed:true ~program_allowed:true)) m

  let default_port_of_protocol = function
    | RamenProtocols.Collectd -> 25826
    | RamenProtocols.NetflowV5 -> 2055

  let net_protocol m =
    let m = "network protocol" :: m in
    ((strinG "collectd" >>: fun () -> RamenProtocols.Collectd) |||
     ((strinG "netflow" ||| strinG "netflowv5") >>: fun () ->
        RamenProtocols.NetflowV5)) m

  let network_address =
    several ~sep:none (cond "inet address" (fun c ->
      (c >= '0' && c <= '9') ||
      (c >= 'a' && c <= 'f') ||
      (c >= 'A' && c <= 'A') ||
      c == '.' || c == ':') '0') >>:
    fun s ->
      let s = String.of_list s in
      try Unix.inet_addr_of_string s
      with Failure x -> raise (Reject x)

  let inet_addr m =
    let m = "network address" :: m in
    ((string "*" >>: fun () -> Unix.inet_addr_any) |||
     (string "[*]" >>: fun () -> Unix.inet6_addr_any) |||
     (network_address)) m

  let listen_clause m =
    let m = "listen on operation" :: m in
    (strinG "listen" -- blanks --
     optional ~def:() (strinG "for" -- blanks) -+
     net_protocol ++
     optional ~def:None (
       blanks --
       optional ~def:() (strinG "on" -- blanks) -+
       some (inet_addr ++
             optional ~def:None (char ':' -+ some unsigned_decimal_number))) >>:
     fun (proto, addr_opt) ->
        let net_addr, port =
          match addr_opt with
          | None -> Unix.inet_addr_any, default_port_of_protocol proto
          | Some (addr, None) -> addr, default_port_of_protocol proto
          | Some (addr, Some port) -> addr, Num.int_of_num port in
        net_addr, port, proto) m

  let instrumentation_clause m =
    let m = "read instrumentation operation" :: m in
    (strinG "listen" -- blanks --
     optional ~def:() (strinG "for" -- blanks) --
     strinG "instrumentation") m

  (* FIXME: It should be possible to enter separator, null, preprocessor in any order *)
  let read_file_specs m =
    let m = "read file operation" :: m in
    (strinG "read" -- blanks -+
     optional ~def:false (
       strinG "and" -- blanks -- strinG "delete" -- blanks >>:
         fun () -> true) +-
     (strinG "file" ||| strinG "files") +- blanks ++
     quoted_string >>: fun (unlink, fname) ->
       { unlink ; fname }) m

  let csv_specs  m =
    let m = "CSV format" :: m in
    let field =
      non_keyword +- blanks ++ RamenScalar.Parser.typ ++
      optional ~def:true (
        optional ~def:true (
          blanks -+ (strinG "not" >>: fun () -> false)) +-
        blanks +- strinG "null") >>:
      fun ((typ_name, typ), nullable) -> RamenTuple.{ typ_name ; typ ; nullable }
    in
    (optional ~def:"," (
       strinG "separator" -- opt_blanks -+ quoted_string +- opt_blanks) ++
     optional ~def:"" (
       strinG "null" -- opt_blanks -+ quoted_string +- opt_blanks) +-
     char '(' +- opt_blanks ++
     several ~sep:list_sep field +- opt_blanks +- char ')' >>:
     fun ((separator, null), fields) ->
       if separator = null || separator = "" then
         raise (Reject "Invalid CSV separator") ;
       { separator ; null ; fields }) m

  let preprocessor_clause m =
    let m = "file preprocessor" :: m in
    (strinG "preprocess" -- blanks -- strinG "with" -- opt_blanks -+
     quoted_string) m

  let factor_clause m =
    let m = "factors" :: m in
    ((strinG "factor" ||| strinG "factors") -- blanks -+
     several ~sep:list_sep_and non_keyword) m

  type select_clauses =
    | SelectClause of selected_field option list
    | MergeClause of (Expr.t list * float)
    | SortClause of (int * Expr.t option (* until *) * Expr.t list (* by *))
    | WhereClause of Expr.t
    | ExportClause of bool
    | EventTimeClause of RamenEventTime.t
    | FactorClause of string list
    | GroupByClause of Expr.t list
    | TopByClause of ((Expr.t (* N *) * Expr.t (* by *)) * Expr.t (* when *))
    | CommitClause of (commit_spec list * (bool (* before *) * Expr.t))
    | FromClause of string list
    | EveryClause of float
    | ListenClause of (Unix.inet_addr * int * RamenProtocols.net_protocol)
    | InstrumentationClause
    | ExternalDataClause of file_spec
    | PreprocessorClause of string
    | CsvSpecsClause of csv_specs

  let p m =
    let m = "operation" :: m in
    let part =
      (select_clause >>: fun c -> SelectClause c) |||
      (merge_clause >>: fun c -> MergeClause c) |||
      (sort_clause >>: fun c -> SortClause c) |||
      (where_clause >>: fun c -> WhereClause c) |||
      (export_clause >>: fun c -> ExportClause c) |||
      (event_time_clause >>: fun c -> EventTimeClause c) |||
      (group_by >>: fun c -> GroupByClause c) |||
      (top_clause >>: fun c -> TopByClause c) |||
      (commit_clause >>: fun c -> CommitClause c) |||
      (from_clause >>: fun c -> FromClause c) |||
      (every_clause >>: fun c -> EveryClause c) |||
      (listen_clause >>: fun c -> ListenClause c) |||
      (instrumentation_clause >>: fun () -> InstrumentationClause) |||
      (read_file_specs >>: fun c -> ExternalDataClause c) |||
      (preprocessor_clause >>: fun c -> PreprocessorClause c) |||
      (csv_specs >>: fun c -> CsvSpecsClause c) |||
      (factor_clause >>: fun c -> FactorClause c) in
    (several ~sep:blanks part >>: fun clauses ->
      (* Used for its address: *)
      let default_select_fields = []
      and default_star = true
      and default_merge = [], 0.
      and default_sort = None
      and default_where = Expr.expr_true
      and default_export = false
      and default_event_time = None
      and default_key = []
      and default_top = None
      and default_commit = ([], (false, default_commit_when))
      and default_from = []
      and default_every = 0.
      and default_listen = None
      and default_instrumentation = false
      and default_ext_data = None
      and default_preprocessor = ""
      and default_csv_specs = None
      and default_factors = [] in
      let default_clauses =
        default_select_fields, default_star, default_merge, default_sort,
        default_where, default_export, default_event_time, default_key,
        default_top, default_commit, default_from, default_every,
        default_listen, default_instrumentation, default_ext_data,
        default_preprocessor, default_csv_specs, default_factors in
      let select_fields, and_all_others, merge, sort, where, force_export,
          event_time, key, top, commit, from, every, listen, instrumentation,
          ext_data, preprocessor, csv_specs, factors =
        List.fold_left (
          fun (select_fields, and_all_others, merge, sort, where, export,
               event_time, key, top, commit, from, every, listen,
               instrumentation, ext_data, preprocessor, csv_specs, factors) ->
            function
            | SelectClause fields_or_stars ->
              let fields, and_all_others =
                List.fold_left (fun (fields, and_all_others) -> function
                    | Some f -> f::fields, and_all_others
                    | None when not and_all_others -> fields, true
                    | None -> raise (Reject "All fields (\"*\") included several times")
                  ) ([], false) fields_or_stars in
              (* The above fold_left inverted the field order. *)
              let select_fields = List.rev fields in
              select_fields, and_all_others, merge, sort, where, export,
              event_time, key, top, commit, from, every, listen,
              instrumentation, ext_data, preprocessor, csv_specs, factors
            | MergeClause merge ->
              select_fields, and_all_others, merge, sort, where, export,
              event_time, key, top, commit, from, every, listen,
              instrumentation, ext_data, preprocessor, csv_specs, factors
            | SortClause sort ->
              select_fields, and_all_others, merge, Some sort, where, export,
              event_time, key, top, commit, from, every, listen,
              instrumentation, ext_data, preprocessor, csv_specs, factors
            | WhereClause where ->
              select_fields, and_all_others, merge, sort, where, export,
              event_time, key, top, commit, from, every, listen,
              instrumentation, ext_data, preprocessor, csv_specs, factors
            | ExportClause export ->
              select_fields, and_all_others, merge, sort, where, export,
              event_time, key, top, commit, from, every, listen,
              instrumentation, ext_data, preprocessor, csv_specs, factors
            | EventTimeClause event_time ->
              select_fields, and_all_others, merge, sort, where, export,
              Some event_time, key, top, commit, from, every, listen,
              instrumentation, ext_data, preprocessor, csv_specs, factors
            | GroupByClause key ->
              select_fields, and_all_others, merge, sort, where, export,
              event_time, key, top, commit, from, every, listen,
              instrumentation, ext_data, preprocessor, csv_specs, factors
            | CommitClause commit' ->
              if commit != default_commit then
                raise (Reject "Cannot have several commit clauses") ;
              select_fields, and_all_others, merge, sort, where, export,
              event_time, key, top, commit', from, every, listen,
              instrumentation, ext_data, preprocessor, csv_specs, factors
            | TopByClause top ->
              select_fields, and_all_others, merge, sort, where, export,
              event_time, key, Some top, commit, from, every, listen,
              instrumentation, ext_data, preprocessor, csv_specs, factors
            | FromClause from' ->
              select_fields, and_all_others, merge, sort, where, export,
              event_time, key, top, commit, (List.rev_append from' from),
              every, listen, instrumentation, ext_data, preprocessor,
              csv_specs, factors
            | EveryClause every ->
              select_fields, and_all_others, merge, sort, where, export,
              event_time, key, top, commit, from, every, listen,
              instrumentation, ext_data, preprocessor, csv_specs, factors
            | ListenClause l ->
              select_fields, and_all_others, merge, sort, where, export,
              event_time, key, top, commit, from, every, Some l,
              instrumentation, ext_data, preprocessor, csv_specs, factors
            | InstrumentationClause ->
              select_fields, and_all_others, merge, sort, where, export,
              event_time, key, top, commit, from, every, listen, true,
              ext_data, preprocessor, csv_specs, factors
            | ExternalDataClause c ->
              select_fields, and_all_others, merge, sort, where, export,
              event_time, key, top, commit, from, every, listen,
              instrumentation, Some c, preprocessor, csv_specs, factors
            | PreprocessorClause preprocessor ->
              select_fields, and_all_others, merge, sort, where, export,
              event_time, key, top, commit, from, every, listen,
              instrumentation, ext_data, preprocessor, csv_specs, factors
            | CsvSpecsClause c ->
              select_fields, and_all_others, merge, sort, where, export,
              event_time, key, top, commit, from, every, listen,
              instrumentation, ext_data, preprocessor, Some c, factors
            | FactorClause factors ->
              select_fields, and_all_others, merge, sort, where, export,
              event_time, key, top, commit, from, every, listen,
              instrumentation, ext_data, preprocessor, csv_specs, factors
          ) default_clauses clauses in
      let commit_specs, commit_before, commit_when, top =
        match commit, top with
        | (commit_specs, (commit_before, commit_when)),
          Some (top, top_when) ->
            if commit_when != default_commit_when ||
               List.exists (function FlushSpec _ -> true
                                   | _ -> false) commit_specs
            then
              raise (Reject "COMMIT and FLUSH clauses are incompatible \
                             with TOP") ;
            commit_specs, commit_before, top_when, Some top
        | (commit_specs, (commit_before, commit_when)), None ->
            commit_specs, commit_before, commit_when, None
      in
      (* Distinguish between Aggregate, Read, ListenFor...: *)
      let not_aggregate =
        select_fields == default_select_fields && sort == default_sort &&
        where == default_where && key == default_key && top == default_top &&
        commit == default_commit
      and not_listen = listen = None || from <> default_from || every <> 0.
      and not_instrumentation = instrumentation = false
      and not_csv =
        ext_data = None && preprocessor == default_preprocessor &&
        csv_specs = None || from <> default_from || every <> 0.
      and not_event_time = event_time = default_event_time
      and not_factors = factors == default_factors in
      if not_listen && not_csv && not_instrumentation then
        let flush_how, notifications =
          List.fold_left (fun (f, n) -> function
            | CommitSpec -> f, n
            | NotifySpec n' -> (f, n'::n)
            | FlushSpec f' ->
                if f = None then (Some f', n)
                else raise (Reject "Several flush clauses")
          ) (None, []) commit_specs in
        let flush_how = flush_how |? Reset in
        Aggregate { fields = select_fields ; and_all_others ; merge ; sort ;
                    where ; force_export ; event_time ; notifications ; key ;
                    top ; commit_before ; commit_when ; flush_how ; from ;
                    every ; factors }
      else if not_aggregate && not_csv && not_event_time &&
              not_instrumentation && listen <> None then
        let net_addr, port, proto = Option.get listen in
        ListenFor { net_addr ; port ; proto ; force_export ; factors }
      else if not_aggregate && not_listen &&
              not_instrumentation &&
              ext_data <> None && csv_specs <> None then
        ReadCSVFile { where = Option.get ext_data ;
                      what = Option.get csv_specs ;
                      preprocessor ;
                      force_export ; event_time ; factors }
      else if not_aggregate && not_listen && not_csv && not_listen &&
              not_factors
      then
        Instrumentation { force_export ; from }
      else
        raise (Reject "Incompatible mix of clauses")
    ) m

  (*$= p & ~printer:(test_printer print)
    (Ok (\
      Aggregate {\
        fields = [\
          { expr = Expr.(Field (typ, ref TupleIn, "start")) ;\
            alias = "start" } ;\
          { expr = Expr.(Field (typ, ref TupleIn, "stop")) ;\
            alias = "stop" } ;\
          { expr = Expr.(Field (typ, ref TupleIn, "itf_clt")) ;\
            alias = "itf_src" } ;\
          { expr = Expr.(Field (typ, ref TupleIn, "itf_srv")) ;\
            alias = "itf_dst" } ] ;\
        and_all_others = false ;\
        merge = [], 0. ;\
        sort = None ;\
        where = Expr.Const (typ, VBool true) ;\
        notifications = [] ;\
        key = [] ; top = None ;\
        commit_when = replace_typ Expr.expr_true ;\
        commit_before = false ;\
        flush_how = Reset ;\
        force_export = false ; event_time = None ;\
        from = ["foo"] ; every = 0. ; factors = [] },\
      (67, [])))\
      (test_op p "from foo select start, stop, itf_clt as itf_src, itf_srv as itf_dst" |>\
       replace_typ_in_op)

    (Ok (\
      Aggregate {\
        fields = [] ;\
        and_all_others = true ;\
        merge = [], 0. ;\
        sort = None ;\
        where = Expr.(\
          StatelessFun2 (typ, Gt, \
            Field (typ, ref TupleIn, "packets"),\
            Const (typ, VI32 (Int32.of_int 0)))) ;\
        force_export = false ; event_time = None ; notifications = [] ;\
        key = [] ; top = None ;\
        commit_when = replace_typ Expr.expr_true ;\
        commit_before = false ;\
        flush_how = Reset ; from = ["foo"] ; every = 0. ; factors = [] },\
      (26, [])))\
      (test_op p "from foo where packets > 0" |> replace_typ_in_op)

    (Ok (\
      Aggregate {\
        fields = [\
          { expr = Expr.(Field (typ, ref TupleIn, "t")) ;\
            alias = "t" } ;\
          { expr = Expr.(Field (typ, ref TupleIn, "value")) ;\
            alias = "value" } ] ;\
        and_all_others = false ;\
        merge = [], 0. ;\
        sort = None ;\
        where = Expr.Const (typ, VBool true) ;\
        force_export = true ; event_time = Some (("t", 10.), RamenEventTime.DurationConst 60.) ;\
        notifications = [] ;\
        key = [] ; top = None ;\
        commit_when = replace_typ Expr.expr_true ;\
        commit_before = false ;\
        flush_how = Reset ; from = ["foo"] ; every = 0. ; factors = [] },\
      (71, [])))\
      (test_op p "from foo select t, value export event starting at t*10 with duration 60" |>\
       replace_typ_in_op)

    (Ok (\
      Aggregate {\
        fields = [\
          { expr = Expr.(Field (typ, ref TupleIn, "t1")) ;\
            alias = "t1" } ;\
          { expr = Expr.(Field (typ, ref TupleIn, "t2")) ;\
            alias = "t2" } ;\
          { expr = Expr.(Field (typ, ref TupleIn, "value")) ;\
            alias = "value" } ] ;\
        and_all_others = false ;\
        merge = [], 0. ;\
        sort = None ;\
        where = Expr.Const (typ, VBool true) ;\
        force_export = true ; event_time = Some (("t1", 10.), RamenEventTime.StopField ("t2", 10.)) ;\
        notifications = [] ; key = [] ; top = None ;\
        commit_when = replace_typ Expr.expr_true ;\
        commit_before = false ;\
        flush_how = Reset ; from = ["foo"] ; every = 0. ; factors = [] },\
      (82, [])))\
      (test_op p "from foo select t1, t2, value export event starting at t1*10 and stopping at t2*10" |>\
       replace_typ_in_op)

    (Ok (\
      Aggregate {\
        fields = [] ;\
        and_all_others = true ;\
        merge = [], 0. ;\
        sort = None ;\
        where = Expr.Const (typ, VBool true) ;\
        force_export = false ; event_time = None ;\
        notifications = [ \
          HttpCmd { method_ = HttpCmdGet ; headers = [] ; body = "" ;\
                    url = "http://firebrigade.com/alert.php" } ];\
        key = [] ; top = None ;\
        commit_when = replace_typ Expr.expr_true ;\
        commit_before = false ;\
        flush_how = Reset ; from = ["foo"] ; every = 0. ; factors = [] },\
      (48, [])))\
      (test_op p "from foo HTTP \"http://firebrigade.com/alert.php\"" |>\
       replace_typ_in_op)

    (Ok (\
      Aggregate {\
        fields = [\
          { expr = Expr.(\
              StatefulFun (typ, LocalState, AggrMin (\
                Field (typ, ref TupleIn, "start")))) ;\
            alias = "start" } ;\
          { expr = Expr.(\
              StatefulFun (typ, LocalState, AggrMax (\
                Field (typ, ref TupleIn, "stop")))) ;\
            alias = "max_stop" } ;\
          { expr = Expr.(\
              StatelessFun2 (typ, Div, \
                StatefulFun (typ, LocalState, AggrSum (\
                  Field (typ, ref TupleIn, "packets"))),\
                Field (typ, ref TupleParam, "avg_window"))) ;\
            alias = "packets_per_sec" } ] ;\
        and_all_others = false ;\
        merge = [], 0. ;\
        sort = None ;\
        where = Expr.Const (typ, VBool true) ;\
        force_export = false ; event_time = None ; \
        notifications = [] ;\
        key = [ Expr.(\
          StatelessFun2 (typ, Div, \
            Field (typ, ref TupleIn, "start"),\
            StatelessFun2 (typ, Mul, \
              Const (typ, VI32 1_000_000l),\
              Field (typ, ref TupleParam, "avg_window")))) ] ;\
        top = None ;\
        commit_when = Expr.(\
          StatelessFun2 (typ, Gt, \
            StatelessFun2 (typ, Add, \
              StatefulFun (typ, LocalState, AggrMax (\
                Field (typ, ref TupleGroupFirst, "start"))),\
              Const (typ, VI32 (Int32.of_int 3600))),\
            Field (typ, ref TupleOut, "start"))) ; \
        commit_before = false ;\
        flush_how = Reset ;\
        from = ["foo"] ; every = 0. ; factors = [] },\
        (199, [])))\
        (test_op p "select min start as start, \\
                           max stop as max_stop, \\
                           (sum packets)/avg_window as packets_per_sec \\
                   from foo \\
                   group by start / (1_000_000 * avg_window) \\
                   commit after out.start < (max group.first.start) + 3600" |>\
         replace_typ_in_op)

    (Ok (\
      Aggregate {\
        fields = [\
          { expr = Expr.Const (typ, VI32 (Int32.one)) ;\
            alias = "one" } ] ;\
        and_all_others = false ;\
        merge = [], 0. ;\
        sort = None ;\
        where = Expr.Const (typ, VBool true) ;\
        force_export = false ; event_time = None ; \
        notifications = [] ;\
        key = [] ; top = None ;\
        commit_when = Expr.(\
          StatelessFun2 (typ, Ge, \
            StatefulFun (typ, LocalState, AggrSum (\
              Const (typ, VI32 (Int32.one)))),\
            Const (typ, VI32 (Int32.of_int 5)))) ;\
        commit_before = true ;\
        flush_how = Reset ; from = ["foo"] ; every = 0. ; factors = [] },\
        (49, [])))\
        (test_op p "select 1 as one from foo commit before sum 1 >= 5" |>\
         replace_typ_in_op)

    (Ok (\
      Aggregate {\
        fields = [\
          { expr = Expr.Field (typ, ref TupleIn, "n") ; alias = "n" } ;\
          { expr = Expr.(\
              StatefulFun (typ, GlobalState, Expr.Lag (\
              Expr.Const (typ, VI32 (Int32.of_int 2)), \
              Expr.Field (typ, ref TupleIn, "n")))) ;\
            alias = "l" } ] ;\
        and_all_others = false ;\
        merge = [], 0. ;\
        sort = None ;\
        where = Expr.Const (typ, VBool true) ;\
        force_export = false ; event_time = None ; \
        notifications = [] ;\
        key = [] ; top = None ;\
        commit_when = replace_typ Expr.expr_true ;\
        commit_before = false ;\
        flush_how = Reset ; from = ["foo/bar"] ; every = 0. ; factors = [] },\
        (37, [])))\
        (test_op p "SELECT n, lag(2, n) AS l FROM foo/bar" |>\
         replace_typ_in_op)

    (Ok (\
      ReadCSVFile { where = { fname = "/tmp/toto.csv" ; unlink = false } ; \
                    preprocessor = "" ; force_export = false ; event_time = None ; \
                    what = { \
                      separator = "," ; null = "" ; \
                      fields = [ \
                        { typ_name = "f1" ; nullable = true ; typ = TBool } ;\
                        { typ_name = "f2" ; nullable = false ; typ = TI32 } ] } ;\
                    factors = [] },\
      (52, [])))\
      (test_op p "read file \"/tmp/toto.csv\" (f1 bool, f2 i32 not null)")

    (Ok (\
      ReadCSVFile { where = { fname = "/tmp/toto.csv" ; unlink = true } ; \
                    preprocessor = "" ; force_export = false ; event_time = None ; \
                    what = { \
                      separator = "," ; null = "" ; \
                      fields = [ \
                        { typ_name = "f1" ; nullable = true ; typ = TBool } ;\
                        { typ_name = "f2" ; nullable = false ; typ = TI32 } ] } ;\
                    factors = [] },\
      (63, [])))\
      (test_op p "read and delete file \"/tmp/toto.csv\" (f1 bool, f2 i32 not null)")

    (Ok (\
      ReadCSVFile { where = { fname = "/tmp/toto.csv" ; unlink = false } ; \
                    preprocessor = "" ; force_export = false ; event_time = None ; \
                    what = { \
                      separator = "\t" ; null = "<NULL>" ; \
                      fields = [ \
                        { typ_name = "f1" ; nullable = true ; typ = TBool } ;\
                        { typ_name = "f2" ; nullable = false ; typ = TI32 } ] } ;\
                    factors = [] },\
      (81, [])))\
      (test_op p "read file \"/tmp/toto.csv\" \\
                      separator \"\\t\" null \"<NULL>\" \\
                      (f1 bool, f2 i32 not null)")

    (Ok (\
      Aggregate {\
        fields = [ { expr = Expr.Const (typ, VI32 1l) ; alias = "one" } ] ;\
        every = 1. ; force_export = true ; event_time = None ;\
        and_all_others = false ; merge = [], 0. ; sort = None ;\
        where = Expr.Const (typ, VBool true) ;\
        notifications = [] ; key = [] ; top = None ;\
        commit_when = replace_typ Expr.expr_true ;\
        commit_before = false ; flush_how = Reset ; from = [] ;\
        factors = [] },\
        (36, [])))\
        (test_op p "YIELD 1 AS one EVERY 1 SECOND EXPORT" |>\
         replace_typ_in_op)
  *)

  (*$>*)
end
