open Batteries
open Stdint
open RamenHelpers

type t (* abstract, represents a ring buffer mmapped file *)

let prepend_rb_name f fname =
  try f fname
  with Failure msg -> failwith (fname ^": "^ msg)

external create_ : bool -> string -> int -> unit = "wrap_ringbuf_create"
let create ?(wrap=true) fname =
  mkdir_all ~is_file:true fname ;
  prepend_rb_name (create_ wrap) fname

type stats = {
  capacity : int ; (* in words *)
  wrap : bool ;
  alloced_words : int ; (* in words *)
  alloc_count : int ;
  t_min : float ;
  t_max : float ;
  mem_size : int ; (* the number of bytes that were mapped *)
  prod_head : int ;
  prod_tail : int ;
  cons_head : int ;
  cons_tail : int ;
  first_seq : int (* taken from per_seq/max file *) }

external load_ : string -> t = "wrap_ringbuf_load"
let load = prepend_rb_name load_
external unload : t -> unit = "wrap_ringbuf_unload"
external stats : t -> stats = "wrap_ringbuf_stats"

type tx (* abstract, represents an ongoing (de)queueing operation *)

external tx_size : tx -> int = "wrap_ringbuf_tx_size"
external enqueue_alloc : t -> int -> tx = "wrap_ringbuf_enqueue_alloc"
external enqueue_commit : tx -> float -> float -> unit = "wrap_ringbuf_enqueue_commit"
external enqueue : t -> bytes -> int -> float -> float -> unit = "wrap_ringbuf_enqueue"
external dequeue_alloc : t -> tx = "wrap_ringbuf_dequeue_alloc"
external dequeue_commit : tx -> unit = "wrap_ringbuf_dequeue_commit"
external dequeue : t -> bytes = "wrap_ringbuf_dequeue"
external read_first : t -> tx = "wrap_ringbuf_read_first"
external read_next : tx -> tx = "wrap_ringbuf_read_next"
external empty_tx : unit -> tx = "wrap_empty_tx"

external write_float : tx -> int -> float -> unit = "write_float"
external write_string : tx -> int -> string -> unit = "write_str"
external write_u8 : tx -> int -> Uint8.t -> unit = "write_boxed_8"
external write_u16 : tx -> int -> Uint16.t -> unit = "write_boxed_16"
external write_u32 : tx -> int -> Uint32.t -> unit = "write_boxed_32"
external write_i32 : tx -> int -> Int32.t -> unit = "write_boxed_32"
external write_u64 : tx -> int -> Uint64.t -> unit = "write_boxed_64"
external write_i64 : tx -> int -> Int64.t -> unit = "write_boxed_64"
external write_u128 : tx -> int -> Uint128.t -> unit = "write_boxed_128"
external write_i128 : tx -> int -> Int128.t -> unit = "write_boxed_128"
external write_eth : tx -> int -> Uint48.t -> unit = "write_boxed_48"
external write_ip4 : tx -> int -> Uint32.t -> unit = "write_boxed_32"
external write_ip6 : tx -> int -> Uint128.t -> unit = "write_boxed_128"
(* Everything passed as an int and which occupancy is <= word *)
external write_bool : tx -> int -> bool -> unit = "write_word"
(* Special to zero the nullmask *)
external zero_bytes : tx -> int -> int -> unit = "zero_bytes"

(* Integers of 8, 16 and 24 bits are stored as normal ocaml integers.
 * But signed int8, int16 and int24 are shifted to the left so that
 * ocaml see them with the proper sign so that arithmetic works.
 * When we encode them using write_u{8,16,24} we must therefore shift
 * them back, as those functions assume only the low bits are relevant.
 * For this, it is enough to call the to_int function, since that's what
 * those functions do: *)
external write_i8_ : tx -> int -> int -> unit = "write_boxed_8"
external write_i16_ : tx -> int -> int -> unit = "write_boxed_16"
let write_i8 tx offs i = write_i8_ tx offs (Int8.to_int i)
let write_i16 tx offs i = write_i16_ tx offs (Int16.to_int i)

let write_cidr4 tx offs (n, l) =
  write_u32 tx offs n ;
  write_u8 tx (offs + RingBufLib.round_up_to_rb_word 4) (Uint8.of_int l)

let write_cidr6 tx offs (n, l) =
  write_u128 tx offs n ;
  write_u16 tx (offs + RingBufLib.round_up_to_rb_word 16) (Uint16.of_int l)

external read_float : tx -> int -> float = "read_float"
external read_string : tx -> int -> string = "read_str"
external read_u8 : tx -> int -> Uint8.t = "read_uint8"
external read_u16 : tx -> int -> Uint16.t = "read_uint16"
external read_u32 : tx -> int -> Uint32.t = "read_uint32"
external read_i32 : tx -> int -> Int32.t = "read_int32"
external read_u64 : tx -> int -> Uint64.t = "read_uint64"
external read_i64 : tx -> int -> Int64.t = "read_int64"
external read_u128 : tx -> int -> Uint128.t = "read_uint128"
external read_i128 : tx -> int -> Int128.t = "read_int128"
external read_eth : tx -> int -> Uint48.t = "read_uint48"
external read_ip4 : tx -> int -> Uint32.t = "read_uint32"
external read_ip6 : tx -> int -> Uint128.t = "read_uint128"
external read_bool : tx -> int -> bool = "read_word"
external read_word : tx -> int -> int = "read_word"

external set_bit : tx -> int -> unit = "set_bit"
external get_bit : tx -> int -> bool = "get_bit"

(* See above as to why int8 and int16 are special: *)
external read_i8_ : tx -> int -> int = "read_int8"
external read_i16_ : tx -> int -> int = "read_int16"
let read_i8 tx offs = Int8.of_int (read_i8_ tx offs)
let read_i16 tx offs = Int16.of_int (read_i16_ tx offs)

let read_cidr4 tx offs =
  let addr = read_u32 tx offs in
  let len = read_u8 tx (offs + RingBufLib.round_up_to_rb_word 4) in
  addr, Uint8.to_int len

let read_cidr6 tx offs =
  let addr = read_u128 tx offs in
  let len = read_u16 tx (offs + RingBufLib.round_up_to_rb_word 16) in
  addr, Uint16.to_int len

(* Have to be there rather than in RingBufLib because it depends on
 * RingBuf. *)
let dequeue_ringbuf_once ?while_ ?delay_rec ?max_retry_time rb =
  RingBufLib.retry_for_ringbuf ?while_ ?delay_rec ?max_retry_time
                               dequeue_alloc rb

let read_ringbuf ?while_ ?delay_rec rb f =
  let open Lwt in
  let rec loop () =
    match%lwt dequeue_ringbuf_once ?while_ ?delay_rec rb with
    | exception (Exit | Timeout) -> return_unit
    | tx ->
      (* f has to call dequeue_commit on the passed tx (as soon as
       * possible): *)
      f tx >>= loop in
  loop ()

let read_buf ?wait_for_more ?while_ ?delay_rec rb init f =
  (* Read tuples by hoping from one to the next using tx_next.
   * Note that we may reach the end of the written content, and will
   * have to wait unless we reached the EOF mark (special value
   * returned by tx_next). *)
  let open Lwt in
  let rec loop usr tx_ =
    match%lwt tx_ with
    | exception (Exit | Timeout | End_of_file) -> return usr
    | exception RingBufLib.Empty ->
        assert (wait_for_more <> Some true) ;
        return usr
    | tx ->
        (* Contrary to the wrapping case, f must not call dequeue_commit.
         * Caller must know in which case it is: *)
        let%lwt usr, more_to_come = f usr tx in
        if more_to_come then
          let tx_ = RingBufLib.retry_for_ringbuf ?while_ ?wait_for_more
                                                 ?delay_rec read_next tx in
          loop usr tx_
        else
          return usr
  in
  let tx_ = RingBufLib.retry_for_ringbuf ?while_ ?wait_for_more ?delay_rec
                                         read_first rb in
  loop init tx_

let with_enqueue_tx rb sz f =
  let open Lwt in
  let%lwt tx =
    RingBufLib.retry_for_ringbuf (enqueue_alloc rb) sz in
  try
    let tmin, tmax = f tx in
    enqueue_commit tx tmin tmax ;
    return_unit
  with exn ->
    (* There is no such thing as enqueue_rollback. We cannot make the rb
     * pointer go backward (or... can we?) but we could have a 1 bit header
     * indicating if an entry is valid or not. *)
    fail exn

let seq_dir_of_bname fname = fname ^".per_seq/"
let time_dir_of_bname fname = fname ^".per_time/"

let int_of_hex s = int_of_string ("0x"^ s)

let seq_files_of dir =
  (try Sys.files_of dir
  with Sys_error _ -> Enum.empty ()) //@
  (fun fname ->
    try
      let mi, rest = String.split ~by:"-" fname in
      let ma, _rest = String.split ~by:"." rest in
      Some (int_of_hex mi, int_of_hex ma, dir ^"/"^ fname)
    with Not_found | Failure _ ->
      None)

let seq_file_compare (f1, _, _) (f2, _, _) =
  Int.compare f1 f2

external strtod : string -> float = "wrap_strtod"

let time_files_of dir =
  (try Sys.files_of dir
  with Sys_error _ -> Enum.empty ()) //@
  (fun fname ->
    try
      let t1, rest = String.split ~by:"-" fname in
      let t2, _rest = String.split ~by:"." rest in
      Some (strtod t1, strtod t2, dir ^"/"^ fname)
    with Not_found | Failure _ ->
      None)

let seq_range bname =
  (* Returns the first and last available seqnums.
   * Takes first from the per.seq subdir names and last from same subdir +
   * rb->stats. *)
  let dir = seq_dir_of_bname bname in
  let mi_ma =
    seq_files_of dir |>
    Enum.fold (fun mi_ma (from, to_, _fname) ->
      match mi_ma with
      | None -> Some (from, to_)
      | Some (mi, ma) -> Some (min mi from, max ma to_)
    ) None in
  let rb = load bname in
  let s = finally (fun () -> unload rb) stats rb in
  match mi_ma with
  | None -> s.first_seq, s.alloc_count
  | Some (mi, ma) -> mi, s.first_seq + s.alloc_count
