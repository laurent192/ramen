(* Tools for LWT IOs *)
open Lwt

let dying task =
  Lwt.fail_with (Printf.sprintf "Committing suicide while %s\n%!" task)

let always_true () = true

let read_file_lines ?(do_unlink=false) ?(alive=always_true) filename of_string k =
  match%lwt Lwt_unix.(openfile filename [ O_RDONLY ] 0x644) with
  | exception e ->
    Printf.eprintf "Cannot open file %S: %s, skipping.\n%!"
      filename (Printexc.to_string e) ;
    return_unit
  | fd ->
    let%lwt () =
      if do_unlink then Lwt_unix.unlink filename else return_unit in
    let chan = Lwt_io.(of_fd ~mode:input fd) in
    let rec read_next_line () =
      if alive () then (
        match%lwt Lwt_io.read_line chan with
        | exception End_of_file -> return_unit
        | line ->
          (match of_string line with
          | exception e ->
            Printf.eprintf "Cannot parse line %S: %s\n%!" line (Printexc.to_string e) ;
            read_next_line ()
          | x ->
            let rec loop () =
              (match k x with
              (* FIXME: a dedicated RingBuf.NoMoreRoom exception *)
              | exception (Failure _) ->
                Printf.eprintf "No more space in the ring buffer, sleeping...\n%!" ;
                (* TODO: an automatic retry-er that tries to find out the best
                 * amount of time to sleep based on successive errors *)
                Lwt_unix.sleep 1. >>= loop
              | exception e ->
                Printf.eprintf "Cannot serialize line %S: %s\n%!" line (Printexc.to_string e) ;
                read_next_line ()
              | () -> read_next_line ())
            in
            loop ())
      ) else (
        dying (Printf.sprintf "reading %S" filename)
      )
    in
    let%lwt () = read_next_line () in
    Printf.printf "done reading %S\n%!" filename ;
    return_unit
