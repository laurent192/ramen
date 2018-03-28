open Batteries
open RamenLog
open Helpers
module C = RamenConf
module N = C.Func
module L = C.Program

let propose (l, h) =
  String.print stdout l ;
  if h <> "" then (
    Char.print stdout '\t' ;
    String.print stdout h) ;
  print_endline ""

let complete lst s =
  List.filter (fun (l, _) -> String.starts_with l s) lst |>
  List.iter propose

let complete_commands s =
  let commands =
    [ "start", Consts.start_info ;
      "shutdown", Consts.shutdown_info ;
      "compile", Consts.compile_info ;
      "run", Consts.run_info ;
      "tail", Consts.tail_info ;
      "timeseries", Consts.timeseries_info ] in
  complete commands s

let complete_global_options s =
  let options =
    [ "--help", "" ;
      "--version", "" ] in
  complete options s

let find_opt o =
  let opt_value s =
    String.split s ~by:"=" |> snd in
  let o_eq = o ^ "=" in
  let find_opt_1 s =
    if String.starts_with s o_eq then opt_value s else
    raise Not_found in
  let rec loop = function
  | [] -> raise Not_found
  | [s] -> find_opt_1 s
  | s::(n::_ as rest) ->
      if s = o then n else
      try find_opt_1 s
      with Not_found -> loop rest in
  fun lst -> loop lst

let root toks =
  try find_opt "--root" toks
  with Not_found ->
    try Sys.getenv "RAMEN_ROOT"
    with Not_found -> ""

let persist_dir toks =
  try find_opt "--persist-dir" toks
  with Not_found -> Consts.default_persist_dir

let complete_file select root str =
  let res = ref [] in
  let on_file fname rel_fname =
    if select fname then
      res :=
        (* If we had no root then we are relative to current directory,
         * therefore it's nicer to omit the root entirely: *)
        ((if root = "" then rel_fname else fname),
         "ramen program ") :: !res in
  dir_subtree_iter ~on_file (if root = "" then Sys.getcwd () else root) ;
  !res

let extension_is ext fname =
  String.ends_with fname ext

let complete_program_files root str =
  complete_file (extension_is ".ramen") root str

let complete_binary_files root str =
  complete_file (extension_is ".x") root str

let complete_running_function persist_dir str =
  (* TODO: have a single file of "must be running" programs,
   * and an advisory lock to protect this. *)
  failwith "TODO"

let complete str () =
  (* Tokenize str, find where we are: *)
  let last_tok_is_complete =
    let len = String.length str in
    len > 0 && Char.is_whitespace str.[len - 1] in
  let toks =
    String.split_on_char ' ' str |>
    List.filter (fun s -> String.length s > 0) in
  let toks =
    match toks with
    | s :: rest when String.ends_with s "ramen" -> rest
    | r -> r (* ?? *) in
  let nb_toks = List.length toks in
  let command_idx, command =
    try List.findi (fun i s -> s.[0] <> '-') toks
    with Not_found -> -1, "" in
  let last_tok =
    if nb_toks > 0 then List.nth toks (nb_toks-1)
    else "" in
  (*!logger.info "nb_toks=%d, command_idx=%d, command=%s, last_tok_complete=%b"
    nb_toks command_idx command last_tok_is_complete ;*)

  (match nb_toks, command_idx, last_tok_is_complete with
  | 0, _, true -> (* "ramen<TAB>" *)
    complete_commands ""
  | 0, _, false -> (* "ramen <TAB>" *)
    complete_commands ""
  | _, -1, false -> (* "ramen [[other options]] --...<TAB>" *)
    complete_global_options last_tok
  | _, c_idx, false when c_idx = nb_toks-1 -> (* "ramen ... comm<TAB>" *)
    complete_commands last_tok
  | _ -> (* "ramen ... command ...? <TAB>" *)
    let toks = List.drop (command_idx+1) toks in
    let completions =
      (match command with
      | "start" ->
          [ "--daemonize", "" ;
            "--help", "" ;
            "--persist-dir=", "" ;
            "--seed=", "" ;
            "--log-to-stderr", "" ]
      | "compile" ->
          let root = root toks in
          ("--bundle-dir=", "") ::
          ("--keep-temp-files", "") ::
          ("--help", "") ::
          ("--persist-dir=", "") ::
          ("--root=", "") ::
          ("--embedded-compiler", "") ::
          (complete_program_files root last_tok)
      | "run" ->
          let root = root toks in
          ("--help", "") ::
          ("--persist-dir=", "") ::
          ("--seed=", "") ::
          ("--parameter=", "") ::
          ("--root=", "") ::
          (complete_binary_files root last_tok)
      | "tail" ->
          let persist_dir = persist_dir toks in
          ("--help", "") ::
          ("--last=", "") ::
          ("--max-seqnum=", "") ::
          ("--min-seqnum=", "") ::
          ("--null=", "") ::
          ("--separator=", "") ::
          ("--seed=", "") ::
          ("--persist-dir", "") ::
          ("--with-header", "") ::
          ("--with-seqnums", "") ::
          (complete_running_function persist_dir last_tok)
      | "shutdown"
      | "timeseries"
      | _ -> []) in
    complete completions (if last_tok_is_complete then "" else last_tok)) ;

  Printf.printf "GOT\t%S\n" str
