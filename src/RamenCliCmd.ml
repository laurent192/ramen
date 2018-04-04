(* For each ramen command, check arguments and mostly transfer the control
 * further to more specialized modules. *)
open Batteries
open Lwt
open Stdint
open RamenLog
open RamenHelpers
module C = RamenConf
module F = RamenConf.Func
module P = RamenConf.Program

let () =
  async_exception_hook := (fun exn ->
    !logger.error "Received exception %s\n%s"
      (Printexc.to_string exn)
      (Printexc.get_backtrace ()))

let make_copts debug persist_dir rand_seed keep_temp_files =
  (match rand_seed with
  | None -> Random.self_init ()
  | Some seed -> Random.init seed) ;
  C.make_conf ~debug ~keep_temp_files persist_dir

(*
 * `ramen start`
 *
 * Start the process supervisor, which will keep running the programs
 * present in the configuration/rc file (and kill the others).
 * This does not return (under normal circumstances).
 *
 * The actual work is done in module RamenProcesses.
 *)

let start conf daemonize to_stderr max_archives () =
  if to_stderr && daemonize then
    failwith "Options --daemonize and --to-stderr are incompatible." ;
  let logdir =
    if to_stderr then None else Some (conf.C.persist_dir ^"/log") in
  Option.may mkdir_all logdir ;
  logger := make_logger ?logdir conf.C.debug ;
  if daemonize then do_daemonize () ;
  let open RamenProcesses in
  let notify_rb = prepare_start conf in
  Lwt_main.run (
    join [
      (let%lwt () = Lwt_unix.sleep 1. in
       (* TODO: Also a separate command to do the cleaning? *)
       async (fun () ->
         restart_on_failure (cleanup_old_files max_archives) conf) ;
       async (fun () ->
         restart_on_failure process_notifications notify_rb) ;
       return_unit) ;
      (* The main job of this process is to make what's actually running
       * in accordance to the running program list: *)
      restart_on_failure synchronize_running conf ])

(*
 * `ramen compile`
 *
 * Turn a ramen program into an executable binary.
 * Actual work happens in RamenCompiler.
 *)

let compile conf root_path use_embedded_compiler bundle_dir
            max_simult_compils source_files () =
  logger := make_logger conf.C.debug ;
  (* There is a long way to calling the compiler so we configure it from
   * here: *)
  RamenOCamlCompiler.use_embedded_compiler := use_embedded_compiler ;
  RamenOCamlCompiler.bundle_dir := bundle_dir ;
  RamenOCamlCompiler.max_simult_compilations := max_simult_compils ;
  let all_ok = ref true in
  let comp_file source_file =
    let program_name = Filename.remove_extension source_file |>
                       rel_path_from root_path
    and program_code = read_whole_file source_file in
    RamenCompiler.compile conf root_path program_name program_code
  in
  List.iter (fun source_file ->
    try
      comp_file source_file
    with e ->
      print_exception e ;
      all_ok := false
  ) source_files ;
  if not !all_ok then exit 1

(*
 * `ramen run`
 *
 * Ask the ramen daemon to start a compiled program.
 *)

let run conf parameters bin_files () =
  logger := make_logger conf.C.debug ;
  Lwt_main.run (
    C.with_wlock conf (fun running_programs ->
      List.iter (fun bin ->
        let bin = absolute_path_of bin in
        let rc = P.of_bin bin in
        let program_name = (List.hd rc).F.program_name in
        Hashtbl.add running_programs program_name C.{ bin ; parameters }
      ) bin_files ;
      return_unit))

(*
 * `ramen kill`
 *
 * Remove that program from the list of running programs.
 * This time the program is identified by its name not its executable file.
 * TODO: warn if this orphans some children.
 *)

let kill conf prog_name () =
  logger := make_logger conf.C.debug ;
  let nb_kills =
    Lwt_main.run (
      C.with_wlock conf (fun running_programs ->
        let before = Hashtbl.length running_programs in
        Hashtbl.filteri_inplace (fun name _mre ->
          name <> prog_name
        ) running_programs ;
        return (before - Hashtbl.length running_programs))) in
  Printf.printf "Killed %d program%s\n"
    nb_kills (if nb_kills > 1 then "s" else "")

(*
 * `ramen ps`
 *
 * Display information about running programs and quit.
 *)

let no_stats = None, None, None, None, 0., Uint64.zero, None, None, None, None

let add_stats (in_count', selected_count', out_count', group_count', cpu',
              ram', wait_in', wait_out', bytes_in', bytes_out')
              (in_count, selected_count, out_count, group_count, cpu,
               ram, wait_in, wait_out, bytes_in, bytes_out) =
  let combine_opt f a b =
    match a, b with None, b -> b | a, None -> a
    | Some a, Some b -> Some (f a b) in
  let add_nu64 = combine_opt Uint64.add
  and add_nfloat = combine_opt (+.)
  in
  add_nu64 in_count' in_count,
  add_nu64 selected_count' selected_count,
  add_nu64 out_count' out_count,
  add_nu64 group_count' group_count,
  cpu' +. cpu,
  Uint64.add ram' ram,
  add_nfloat wait_in' wait_in,
  add_nfloat wait_out' wait_out,
  add_nu64 bytes_in' bytes_in,
  add_nu64 bytes_out' bytes_out

let read_stats conf =
  let h = Hashtbl.create 57 in
  let open RamenScalar in
  let bname = C.report_ringbuf conf in
  let typ = RamenBinocle.tuple_typ in
  let event_time = RamenBinocle.event_time in
  let now = Unix.gettimeofday () in
  let until = now -. 10. in
  let since = until -. 60. in
  let get_string = function VString s -> s
  and get_u64 = function VU64 n -> n
  and get_nu64 = function VNull -> None | VU64 n -> Some n
  and get_float = function VFloat f -> f
  and get_nfloat = function VNull -> None | VFloat f -> Some f
  in
  Lwt_main.run (
    let while_ () = (* Do not wait more than 1s: *)
      return (Unix.gettimeofday () -. now < 1.) in
    RamenSerialization.fold_time_range ~while_ bname typ event_time since until ()  (fun () tuple t1 t2 ->
    let worker = get_string tuple.(0)
    and time = get_float tuple.(1)
    and in_count = get_nu64 tuple.(2)
    and selected_count = get_nu64 tuple.(3)
    and out_count = get_nu64 tuple.(4)
    and group_count = get_nu64 tuple.(5)
    and cpu = get_float tuple.(6)
    and ram = get_u64 tuple.(7)
    and wait_in = get_nfloat tuple.(8)
    and wait_out = get_nfloat tuple.(9)
    and bytes_in = get_nu64 tuple.(10)
    and bytes_out = get_nu64 tuple.(11)
    in
    let stats = in_count, selected_count, out_count, group_count, cpu,
                ram, wait_in, wait_out, bytes_in, bytes_out in
    Hashtbl.modify_opt worker (function
      | None -> Some (time, stats)
      | Some (time', stats') as prev ->
          if time' > time then prev else Some (time, stats)
    ) h)) ;
  h [@@ocaml.warning "-8"]

let int_or_na = function
  | None -> TermTable.ValStr "n/a"
  | Some i -> TermTable.ValInt (Uint64.to_int i)

let flt_or_na = function
  | None -> TermTable.ValStr "n/a"
  | Some f -> TermTable.ValFlt f

let str_or_na = function
  | None -> TermTable.ValStr "n/a"
  | Some s -> TermTable.ValStr s

let time_or_na = function
  | None -> TermTable.ValStr "n/a"
  | Some f -> TermTable.ValStr (string_of_time f)

let ps conf short sort_col top () =
  logger := make_logger conf.C.debug ;
  (* Start by reading the last minute of instrumentation data: *)
  let stats = read_stats conf in
  (* Now iter over all workers and display those stats: *)
  let open TermTable in
  let head, lines =
    if short then
      (* For --short, we sum everything by program: *)
      let h = Hashtbl.create 17 in
      Hashtbl.iter (fun worker (time, stats) ->
        let program, _ = C.program_func_of_user_string worker in
        Hashtbl.modify_opt program (function
          | None -> Some (time, stats)
          | Some (time', stats') -> Some (time, add_stats stats' stats)
        ) h
      ) stats ;
      [| "program" ; "#in" ; "#selected" ; "#out" ; "#groups" ; "CPU" ;
         "wait in" ; "wait out" ; "heap" ; "volume in" ; "volume out" |],
      Hashtbl.fold (fun program_name
                        (_, (in_count, selected_count, out_count, group_count,
                        cpu, ram, wait_in, wait_out, bytes_in, bytes_out))
                        lines ->
        [| ValStr program_name ;
           int_or_na in_count ;
           int_or_na selected_count ;
           int_or_na out_count ;
           int_or_na group_count ;
           ValFlt cpu ;
           flt_or_na wait_in ;
           flt_or_na wait_out ;
           ValInt (Uint64.to_int ram) ;
           flt_or_na (Option.map Uint64.to_float bytes_in) ;
           flt_or_na (Option.map Uint64.to_float bytes_out) |] :: lines
      ) h []
    else
      (* Otherwise we want to display all we can about individual workers *)
      Lwt_main.run (
        C.with_rlock conf (fun programs ->
          return (
            [| "operation" ; "#in" ; "#selected" ; "#out" ; "#groups" ;
               "CPU" ; "wait in" ; "wait out" ; "heap" ;
               "volume in" ; "volume out" ; "#parents" ; "signature" |],
            Hashtbl.fold (fun program_name get_rc lines ->
              let bin, rc = get_rc () in
              List.fold_left (fun lines func ->
                let fq_name = program_name ^"/"^ func.F.name in
                let _, (in_count, selected_count, out_count, group_count,
                        cpu, ram, wait_in, wait_out, bytes_in, bytes_out) =
                  Hashtbl.find_default stats fq_name (0., no_stats) in
                [| ValStr fq_name ;
                   int_or_na in_count ;
                   int_or_na selected_count ;
                   int_or_na out_count ;
                   int_or_na group_count ;
                   ValFlt cpu ;
                   flt_or_na wait_in ;
                   flt_or_na wait_out ;
                   ValInt (Uint64.to_int ram) ;
                   flt_or_na (Option.map Uint64.to_float bytes_in) ;
                   flt_or_na (Option.map Uint64.to_float bytes_out) ;
                   ValInt (List.length func.F.parents) ;
                   ValStr func.signature |] :: lines
              ) lines rc
            ) programs []))) in
  print_table ~sort_col ?top head lines

(*
 * `ramen tail`
 *
 * Display the last tuple output by an operation.
 *
 * This first create a non-wrapping buffer file and then asks the operation
 * to write in there for 1 hour (by default).
 * This buffer name is standard so that other clients wishing to read those
 * tuples can reuse the same and benefit from a shared history.
 *)

let always_true _ = true

let tail conf func_name with_header separator null
         last min_seq max_seq with_seqnums duration () =
  logger := make_logger conf.C.debug ;
  (* Do something useful by default: tail forever *)
  let last =
    if last = None && min_seq = None && max_seq = None then Some min_int
    else last in
  let bname, filter, typ =
    (* Read directly from the instrumentation ringbuf when func_name ends
     * with "#stats" *)
    if func_name = "stats" || String.ends_with func_name "#stats" then
      let typ = RamenTuple.{ user = RamenBinocle.tuple_typ ;
                             ser = RamenBinocle.tuple_typ } in
      let wi = RamenSerialization.find_field_index typ.ser "worker" in
      let filter =
        if func_name = "stats" then always_true else
        let func_name, _ = String.rsplit func_name ~by:"#" in
        fun tuple -> tuple.(wi) = RamenScalar.VString func_name in
      let bname = C.report_ringbuf conf in
      bname, filter, typ
    else
      (* Create the non-wrapping RingBuf (under a standard name given
       * by RamenConf *)
      Lwt_main.run (
        let%lwt func, bname =
          RamenExport.make_temp_export_by_name conf ~duration func_name in
        return (bname, always_true, func.F.out_type))
  in
  (* Find out which seqnums we want to scan: *)
  let mi, ma = RingBuf.seq_range bname in
  let mi = match min_seq with None -> mi | Some m -> max mi m in
  let ma = match max_seq with None -> ma | Some m -> m + 1 (* max_seqnum is in *) in
  let mi, ma = match last with
    | Some l when l >= 0 ->
        let mi = max mi (cap_add ma ~-l) in
        let ma = mi + l in
        mi, ma
    | Some l ->
        assert (l < 0) ;
        let mi = ma
        and ma = cap_add ma (cap_neg l) in
        mi, ma
    | None -> mi, ma in
  !logger.debug "Will display tuples from %d to %d" mi ma ;
  (* Then, scan all present ringbufs in the requested range (either
   * the last N tuples or, TBD, since ts1 [until ts2]) and display
   * them *)
  let nullmask_size =
    RingBufLib.nullmask_bytes_of_tuple_type typ.ser in
  (* I failed the polymorphism dance on that one: *)
  let reorder_column1 = RamenTuple.reorder_tuple_to_user typ in
  let reorder_column2 = RamenTuple.reorder_tuple_to_user typ in
  if with_header then (
    let header = typ.ser |> Array.of_list |> reorder_column1 in
    let first = if with_seqnums then "#Seq"^ separator else "#" in
    Array.print ~first ~last:"\n" ~sep:separator
      (fun fmt ft -> String.print fmt ft.RamenTuple.typ_name)
      stdout header ;
    BatIO.flush stdout) ;
  Lwt_main.run (
    let rec loop m =
      if m >= ma then return_unit else
      let%lwt m =
        let open RamenSerialization in
        fold_seq_range bname ~mi:m ~ma m (fun m tx ->
          let tuple =
            read_tuple typ.ser nullmask_size tx in
          if filter tuple then (
            if with_seqnums then (
              Int.print stdout m ; String.print stdout separator) ;
            reorder_column2 tuple |>
            Array.print ~first:"" ~last:"\n" ~sep:separator
              (RamenScalar.print_custom ~null) stdout ;
            BatIO.flush stdout ;
            return (m + 1)
          ) else return m) in
      if m >= ma then return_unit else
        (* TODO: If we tail for a long time in continuous mode, we might
         * need to refresh the out-ref timeout from time to time. *)
        let delay = 1. +. Random.float 1. in
        let%lwt () = Lwt_unix.sleep delay in
        loop m
    in
    loop mi)

(*
 * `ramen timeseries`
 *
 * Similar to tail, but output only two columns: time and a value, and
 * make sure to provide as many data samples as asked for, consolidating
 * the actual samples as needed.
 *
 * This works only on operations with time-event information and uses the
 * same output archive files as the `ramen tail` command does.
 *)

let timeseries conf since until max_data_points separator null
               func_name data_field consolidation duration () =
  logger := make_logger conf.C.debug ;
  if max_data_points < 1 then failwith "invalid max_data_points" ;
  let since = since |? until -. 600. in
  if since >= until then failwith "since must come strictly before until" ;
  let dt = (until -. since) /. float_of_int max_data_points in
  let open RamenExport in
  let buckets = make_buckets max_data_points in
  let bucket_of_time = bucket_of_time since dt in
  let consolidation =
    match String.lowercase consolidation with
    | "min" -> bucket_min | "max" -> bucket_max | _ -> bucket_avg in
  let bname, filter, typ, event_time =
    (* Read directly from the instrumentation ringbuf when func_name ends
     * with "#stats" *)
    if func_name = "stats" || String.ends_with func_name "#stats" then
      let typ = RamenTuple.{ user = RamenBinocle.tuple_typ ;
                             ser = RamenBinocle.tuple_typ } in
      let wi = RamenSerialization.find_field_index typ.ser "worker" in
      let filter =
        if func_name = "stats" then always_true else
        let func_name, _ = String.rsplit func_name ~by:"#" in
        fun tuple -> tuple.(wi) = RamenScalar.VString func_name in
      let bname = C.report_ringbuf conf in
      bname, filter, typ, RamenBinocle.event_time
    else
      (* Create the non-wrapping RingBuf (under a standard name given
       * by RamenConf *)
      Lwt_main.run (
        let%lwt func, bname =
          make_temp_export_by_name conf ~duration func_name in
        return (bname, always_true, func.F.out_type, func.F.event_time))
  in
  Lwt_main.run (
    let open RamenSerialization in
    let%lwt vi =
      wrap (fun () -> find_field_index typ.ser data_field) in
    fold_time_range bname typ.ser event_time since until () (fun () tuple t1 t2 ->
      if filter tuple then (
        let v = float_of_scalar_value tuple.(vi) in
        let bi1 = bucket_of_time t1 and bi2 = bucket_of_time t2 in
        for bi = bi1 to bi2 do add_into_bucket buckets bi v done))) ;
  (* Display results: *)
  for i = 0 to Array.length buckets - 1 do
    let t = since +. dt *. (float_of_int i +. 0.5)
    and v = consolidation buckets.(i) in
    Float.print stdout t ;
    String.print stdout separator ;
    (match v with None -> String.print stdout null
                | Some v -> Float.print stdout v) ;
    String.print stdout "\n"
  done

(*
 * `ramen timerange`
 *
 * Obtain information about the time range available for timeseries.
 *)

let timerange conf func_name () =
  logger := make_logger conf.C.debug ;
  match C.program_func_of_user_string func_name with
  | exception Not_found ->
      !logger.error "Cannot find function %S" func_name ;
      exit 1
  | program_name, func_name ->
      let mi_ma =
        Lwt_main.run (
          C.with_rlock conf (fun programs ->
            (* We need the func to know its buffer location *)
            let func = C.find_func programs program_name func_name in
            let bname = C.archive_buf_name conf func in
            let typ = func.F.out_type.ser in
            RamenSerialization.time_range bname typ func.F.event_time))
      in
      match mi_ma with
        | None -> Printf.printf "No time info or no output yet.\n"
        | Some (mi, ma) -> Printf.printf "%f %f\n" mi ma