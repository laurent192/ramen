open Batteries
open Lwt
open RamenHelpers
open RamenLog
module C = RamenConf
module F = RamenConf.Func
module P = RamenConf.Program

type tuple_spec = (string, string) Hashtbl.t [@@ppp PPP_OCaml]

module Input = struct
  type spec =
    { pause : float [@ppp_default 0.] ;
      operation : string ;
      tuple : tuple_spec }
    [@@ppp PPP_OCaml]
end

module Output = struct
  type spec =
    { present : tuple_spec list [@ppp_default []] ;
      absent : tuple_spec list [@ppp_default []] ;
      timeout : float [@ppp_default 5.] }
    [@@ppp PPP_OCaml]
end

module Notifs = struct
  type spec =
    { present : string list [@ppp_default []] ;
      absent : string list [@ppp_default []] ;
      timeout : float [@ppp_default 5.] }
    [@@ppp PPP_OCaml]
end

type test_spec =
  { programs : (string * RamenTuple.params) list ;
    inputs : Input.spec list [@ppp_default []] ;
    outputs : (string, Output.spec) Hashtbl.t
      [@ppp_default Hashtbl.create 0] ;
    notifications : Notifs.spec
      [@ppp_default Notifs.{ present=[]; absent=[]; timeout=0. }] }
    [@@ppp PPP_OCaml]

(* Read a tuple described by the given type, and return a hash of fields
 * to string values *)

let fail_and_quit msg =
  RamenProcesses.quit := true ;
  fail_with msg

let compare_miss bad1 bad2 =
  (* TODO: also look at the values *)
  Int.compare (List.length bad1) (List.length bad2)

let test_output func bname output_spec =
  let ser_type = func.F.out_type.ser in
  let nullmask_sz =
    RingBufLib.nullmask_bytes_of_tuple_type ser_type in
  (* Change the hashtable of field to value into a list of field index
   * and value: *)
  let field_index_of_name field =
    match List.findi (fun _ ftyp ->
            ftyp.RamenTuple.typ_name = field
          ) ser_type with
    | exception Not_found ->
        let msg = Printf.sprintf "Unknown field %s in %s" field
                    (IO.to_string RamenTuple.print_typ ser_type) in
        RamenProcesses.quit := true ;
        failwith msg
    | idx, _ -> idx in
  (* The other way around to print the results: *)
  let field_name_of_index idx =
    (List.nth ser_type idx).RamenTuple.typ_name in
  let field_indices_of_tuples =
    List.map (fun spec ->
      Hashtbl.enum spec /@
      (fun (field, value) ->
        field_index_of_name field, value) |>
      List.of_enum, ref []) in
  let%lwt tuples_to_find = wrap (fun () -> ref (
    field_indices_of_tuples output_spec.Output.present)) in
  let%lwt tuples_must_be_absent = wrap (fun () ->
    field_indices_of_tuples output_spec.Output.absent) in
  let tuples_to_not_find = ref [] in
  let start = Unix.gettimeofday () in
  (* With tuples that must be absent, when to stop listening?
   * For now the rule is simple:
   * for as long as we have not yet received some tuples that
   * must be present and the time did not ran out. *)
  let while_ () =
    return (
      !tuples_to_find <> [] &&
      !tuples_to_not_find = [] &&
      not !RamenProcesses.quit &&
      Unix.gettimeofday () -. start < output_spec.timeout) in
  let unserialize = RamenSerialization.read_tuple ser_type nullmask_sz in
  !logger.debug "Enumerating tuples from %s" bname ;
  let%lwt nb_tuples =
    RamenSerialization.fold_seq_range ~wait_for_more:true ~while_ bname 0 (fun count _seq tx ->
      let tuple = unserialize tx in
      !logger.debug "Read a tuple out of operation %S" func.F.name ;
      tuples_to_find :=
        List.filter (fun (spec, best_miss) ->
          let miss =
            List.fold_left (fun miss (idx, value) ->
              (* FIXME: instead of comparing in string we should try to parse
               * the expected value (once and for all -> faster) so that we
               * also check its type. *)
              let s = RamenScalar.to_string tuple.(idx) in
              let ok = s = value in
              if ok then miss else (
                !logger.debug "found %S instead of %S" s value ;
                (idx, s)::miss)
            ) [] spec in
          if miss = [] then false
          else (
            if !best_miss = [] || compare_miss miss !best_miss < 0 then
              best_miss := miss ;
            true
          )
        ) !tuples_to_find ;
      tuples_to_not_find :=
        List.filter (fun (spec, _) ->
          List.for_all (fun (idx, value) ->
            RamenScalar.to_string tuple.(idx) = value) spec
        ) tuples_must_be_absent |>
        List.rev_append !tuples_to_not_find ;
      return (count + 1)) in
  let success = !tuples_to_find = [] && !tuples_to_not_find = [] in
  let file_spec_print best_miss oc (idx, value) =
    (* Retrieve actual field name: *)
    let n = field_name_of_index idx in
    Printf.fprintf oc "%s=%s" n value ;
    match List.find (fun (idx', s) -> idx = idx') best_miss with
    | exception Not_found -> ()
    | _idx, s -> Printf.fprintf oc " (had %S)" s
  in
  let tuple_spec_print oc (spec, best_miss) =
    List.fast_sort (fun (i1, _) (i2, _) -> Int.compare i1 i2) spec |>
    List.print (file_spec_print !best_miss) oc in
  let msg =
    if success then "" else
    (Printf.sprintf "Enumerated %d tuple%s from %s/%s"
      nb_tuples (if nb_tuples > 0 then "s" else "")
      func.F.program_name func.F.name)^
    (if !tuples_to_find = [] then "" else
      " but could not find these tuples: "^
        IO.to_string (List.print tuple_spec_print) !tuples_to_find) ^
    (if !tuples_to_not_find = [] then "" else
      " and found these tuples: "^
        IO.to_string (List.print tuple_spec_print) !tuples_to_not_find)
  in
  return (success, msg)

let test_notifications notify_rb notif_spec =
  (* We keep pat in order to be able to print it later: *)
  let to_regexp pat = pat, Str.regexp pat in
  let notifs_must_be_absent = List.map to_regexp notif_spec.Notifs.absent
  and notifs_to_find = ref (List.map to_regexp notif_spec.Notifs.present)
  and notifs_to_not_find = ref []
  and start = Unix.gettimeofday () in
  let while_ () =
    if !notifs_to_find <> [] &&
       !notifs_to_not_find = [] &&
       Unix.gettimeofday () -. start < notif_spec.timeout
    then return_true else return_false in
  let%lwt () =
    RamenSerialization.read_notifs ~while_ notify_rb (fun (worker, url) ->
      !logger.debug "Got notification from %s: %S" worker url ;
      notifs_to_find :=
        List.filter (fun (_pat, re) ->
          Str.string_match re url 0 |>  not) !notifs_to_find ;
      notifs_to_not_find :=
        List.filter (fun (_pat, re) ->
          Str.string_match re url 0) notifs_must_be_absent |>
        List.rev_append !notifs_to_not_find ;
      return_unit) in
  let success = !notifs_to_find = [] && !notifs_to_not_find = [] in
  let re_print oc (pat, _re) = String.print oc pat in
  let msg =
    if success then "" else
    (if !notifs_to_find = [] then "" else
      "Could not find these notifs: "^
        IO.to_string (List.print re_print) !notifs_to_find) ^
    (if !notifs_to_not_find = [] then "" else
      "Found these notifs: "^
        IO.to_string (List.print re_print) !notifs_to_not_find)
  in
  return (success, msg)

let test_one conf root_path notify_rb dirname test =
  (* Hash from func fq name to its rc, bname and mmapped input ring-buffer: *)
  let workers = Hashtbl.create 11 in
  (* The only sure way to know when to stop the workers is: when the test
   * succeeded, or timeouted. So we start three threads at the same time:
   * the process synchronizer, the worker feeder, and the output evaluator: *)
  (* First, write the list of programs that must run and fill workers
   * hash-table: *)
  let%lwt () =
    C.with_wlock conf (fun running_programs ->
      Hashtbl.clear running_programs ;
      Lwt_list.iter_p (fun (bin, parameters) ->
        (* The path to the binary is relative to the test file: *)
        let bin = absolute_path_of ~rel_to:dirname bin in
        let rc = P.of_bin bin in
        let program_name = (List.hd rc).F.program_name in
        Hashtbl.add running_programs program_name C.{ bin ; parameters } ;
        Lwt_list.iter_s (fun func ->
          (* Each function will archive its output: *)
          let%lwt bname = RamenExport.make_temp_export conf func in
          let fq_name = program_name ^"/"^ func.name in
          Hashtbl.add workers fq_name (func, bname, ref None) ;
          return_unit
        ) rc ;
      ) test.programs) in
  let process_synchroniser =
    restart_on_failure "synchronize_running"
      (RamenProcesses.synchronize_running conf) 0.
  and worker_feeder =
    let feed_input input =
      match Hashtbl.find workers input.Input.operation with
      | exception Not_found ->
          let msg =
            Printf.sprintf2 "Unknown operation: %S (must be one of: %a)"
              input.operation
              (Enum.print String.print) (Hashtbl.keys workers) in
          fail_and_quit msg
      | func, _, rbr ->
          let%lwt () =
            if !rbr = None then (
              if func.F.merge_inputs then
                (* TODO: either specify a parent number or pick the first one? *)
                let err = "Writing to merging operations is not \
                           supported yet!" in
                fail_and_quit err
              else (
                let in_rb = C.in_ringbuf_name_single conf func in
                (* It might not exist already. Instead of waiting for the
                 * worker to start, create it: *)
                RingBuf.create in_rb ;
                let rb = RingBuf.load in_rb in
                rbr := Some rb ;
                return_unit)
            ) else return_unit in
          let rb = Option.get !rbr in
          RamenSerialization.write_tuple conf func.F.in_type.ser rb input.tuple
    in
    let%lwt () =
      Lwt_list.iter_s (fun input ->
        if !RamenProcesses.quit then return_unit
        else feed_input input
      ) test.inputs in
    Hashtbl.iter (fun _ (_, _, rbr) ->
      Option.may RingBuf.unload !rbr
    ) workers ;
    return_unit in
  (* One tester thread per operation *)
  let%lwt tester_threads =
    hash_fold_s test.outputs (fun user_fq_name output_spec thds ->
      let tester_thread =
        match Hashtbl.find workers user_fq_name with
        | exception Not_found ->
            fail_and_quit ("Unknown operation "^ user_fq_name)
        | tested_func, bname, _rbr ->
            test_output tested_func bname output_spec in
      return (tester_thread :: thds)
    ) [] in
  (* Similarly, test the notifications: *)
  let tester_threads =
    finalize
      (fun () -> test_notifications notify_rb test.notifications)
      (fun () ->
        RingBuf.unload notify_rb ;
        (* TODO: unlink *)
        return_unit) :: tester_threads in
  (* Wrap the testers into threads that update this status and set
   * the quit flag: *)
  let all_good = ref true in
  let nb_tests_left = ref (List.length tester_threads) in
  let tester_threads =
    List.map (fun thd ->
      let%lwt success, msg = thd in
      if not success then (
        all_good := false ;
        !logger.error "Failure: %s\n" msg
      ) ;
      decr nb_tests_left ;
      if !nb_tests_left <= 0 then (
        !logger.info "Finished all tests" ;
        RamenProcesses.quit := true
      ) ;
      return_unit) tester_threads in
  let%lwt () =
    join (process_synchroniser :: worker_feeder :: tester_threads) in
  return !all_good

let run conf root_path tests () =
  let conf = { conf with C.persist_dir =
    Filename.get_temp_dir_name ()
      ^"/ramen_test."^ string_of_int (Unix.getpid ()) |>
    uniquify_filename } in
  logger := make_logger conf.C.debug ;
  (* Parse tests so that we won't have to clean anything if they are bogus *)
  let test_specs =
    List.map (fun fname ->
      !logger.info "Parsing test specification in %S..." fname ;
      Filename.dirname fname,
      C.ppp_of_file fname test_spec_ppp_ocaml
    ) tests in
  (* Start Ramen *)
  !logger.info "Starting ramen, using temp dir %s" conf.persist_dir ;
  mkdir_all conf.persist_dir ;
  RamenProcesses.prepare_signal_handlers () ;
  let notify_rb = RamenProcesses.prepare_notifs conf in
  let report_rb = RamenProcesses.prepare_reports conf in
  RingBuf.unload report_rb ;
  (* Run all tests: *)
  (* Note: The workers states must be cleaned in between 2 tests ; the
   * simpler is to draw a new test_id. *)
  let nb_good, nb_tests =
    Lwt_main.run (
      async (fun () ->
        restart_on_failure "wait_all_pids_loop"
          RamenProcesses.wait_all_pids_loop true) ;
      Lwt_list.fold_left_s (fun (nb_good, nb_tests) (dirname,test) ->
        let%lwt res = test_one conf root_path notify_rb dirname test in
        return ((nb_good + if res then 1 else 0), nb_tests + 1)
      ) (0, 0) test_specs) in
  if nb_good = nb_tests then (
    !logger.info "All %d test%s succeeded."
      nb_tests (if nb_tests > 1 then "s" else "")
  ) else
    let nb_fail = nb_tests - nb_good in
    let msg =
      Printf.sprintf "%d test%s failed."
        nb_fail (if nb_fail > 1 then "s" else "") in
    failwith msg
