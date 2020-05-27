(* See RamenNames.mli *)
open Batteries
open RamenHelpersNoLog

type 'a t = string [@@ppp PPP_OCaml] [@@ppp PPP_JSON]

(* Field names *)

type field = [`Field] t

let field_ppp_ocaml = t_ppp_ocaml
let field_ppp_json = t_ppp_json

let field s =
  (* New lines have to be forbidden because of the out_ref ringbuf files.
   * Slashes have to be forbidden because we rsplit to get program names. *)
  if s = "" ||
     String.fold_left (fun bad c ->
       bad || c = '\n' || c = '\r' || c = '/') false s then
    invalid_arg "invalid field name" ;
  s

let field_print = String.print
let field_print_quoted = String.print_quoted (* TODO: or just use color *)

let starts_with c f =
  String.length f > 0 && f.[0] = c

let is_virtual = starts_with '#'
let is_private = starts_with '_'


(* Function names *)

type func = [`Function] t

let func_ppp_ocaml = t_ppp_ocaml
let func_ppp_json = t_ppp_json

let func s =
  (* New lines have to be forbidden because of the out_ref ringbuf files.
   * Slashes have to be forbidden because we rsplit to get program names. *)
  if s = "" ||
     String.fold_left (fun bad c ->
       bad || c = '\n' || c = '\r' || c = '/') false s then
    invalid_arg "invalid function name" ;
  s

let func_print = String.print
let func_print_quoted = String.print_quoted

(* Program names *)

type program = [`Program] t

let program_ppp_ocaml = t_ppp_ocaml
let program_ppp_json = t_ppp_json

let rec remove_heading_slashes s =
  if String.length s > 0 && s.[0] = '/' then
    remove_heading_slashes (String.lchop s)
  else s

let has_dotnames s =
  s = "." || s = ".." ||
  String.starts_with s "./" ||
  String.starts_with s "../" ||
  String.ends_with s "/." ||
  String.ends_with s "/.." ||
  String.exists s "/./" ||
  String.exists s "/../"

let rec simplified_path =
  let open Str in
  let strip_final_slash s =
    let l = String.length s in
    if l > 1 && s.[l-1] = '/' then
      String.rchop s
    else s in
  let res =
    [ regexp "/[^/]+/\\.\\./", "/" ;
      regexp "^[^/]+/\\.\\./", "" ;
      regexp "\\(^\\|/\\)[^/]+/\\.\\.$", "" ;
      regexp "/\\./", "/" ;
      regexp "//", "/" ;
      regexp "/\\.?$", "" ;
      regexp "^\\./", "" ] in
  fun path ->
    let s =
      List.fold_left (fun s (re, repl) ->
        global_replace re repl s
      ) path res in
    if s = path then strip_final_slash s
    else simplified_path s

(*$inject open Batteries *)
(*$inject
  let simplified_path_ p =
    ((simplified_path (path p)) :> string)
*)
(*$= simplified_path_ & ~printer:identity
  "/glop/glop" (simplified_path_ "/glop/glop/")
  "/glop/glop" (simplified_path_ "/glop/glop")
  "glop/glop"  (simplified_path_ "./glop/glop/")
  "glop/glop"  (simplified_path_ "glop/glop/.")
  "/glop/glop" (simplified_path_ "/glop/pas glop/../glop")
  "/glop/glop" (simplified_path_ "/glop/./glop")
  "glop"       (simplified_path_ "glop/.")
  "glop"       (simplified_path_ "glop/./")
  "/glop"      (simplified_path_ "/./glop")
  "/glop/glop" (simplified_path_ "/glop//glop")
  "/glop/glop" (simplified_path_ "/glop/pas glop/..//pas glop/.././//glop//")
  "/glop"      (simplified_path_ "/glop/glop/..")
  "/glop"      (simplified_path_ "/glop/glop/../")
  "t"          (simplified_path_ "c1/c2/../../t")
  "/t"         (simplified_path_ "/c1/c2/../../t")
*)

let program s =
  let s = remove_heading_slashes s in
  if s = "" then
    failwith "Program names must not be empty" else
  if has_dotnames s then
    failwith "Program names cannot include directory dotnames" else
  simplified_path s

(* Make sure a path component is shorter that max_dir_len: *)
let max_dir_len = 255
let md5 str = Digest.(string str |> to_hex)
let abbrev s =
  if String.length s <= max_dir_len then s else md5 s

let path_of_program ~suffix prog =
  (* Clip the suffix: *)
  let prog =
    if suffix then prog else
    match String.rsplit prog ~by:"#" with
    | exception Not_found -> prog
    | prog, _ -> prog in
  (* Maybe abbreviate some path components: *)
  String.split_on_char '/' prog |>
  List.map abbrev |>
  String.join "/"

let suffix_of_program prog =
  match String.rsplit prog ~by:"#" with
  | exception Not_found -> None
  | _, suffix -> Some suffix

let program_print = String.print
let program_print_quoted = String.print_quoted

(* Relative Program Names: "../" are allowed, and conversion to a normal
 * program name requires the location from which the program is relative: *)

type rel_program = [`RelProgram] t

let rel_program_ppp_ocaml = t_ppp_ocaml
let rel_program_ppp_json = t_ppp_json

let rel_program s =
  if s = "" then invalid_arg "relative program name"
  else s

let program_of_rel_program start rel_program =
  (* TODO: for now we just support "../" prefix: *)
  (* TODO: if rel_program is given with a suffix hash but with an empty
   *       suffix it means to look for the same suffix as start: *)
  let rel_program =
    if String.ends_with rel_program "#" then
      match suffix_of_program start with
      | Some suffix ->
          rel_program ^ suffix
      | None ->
          String.rchop ~n:1 rel_program
    else
      rel_program in
  if rel_program = ".." || String.starts_with rel_program "../" then
    simplified_path (start ^"/"^ rel_program)
  else rel_program

let rel_program_print = String.print
let rel_program_print_quoted = String.print_quoted

(* Fully Qualified function names *)

type fq = [`FQ] t

let fq_ppp_ocaml = t_ppp_ocaml
let fq_ppp_json = t_ppp_json

external fq : string -> fq = "%identity"

let fq_of_program prog func = prog ^"/"^ func

let fq_print = String.print
let fq_print_quoted = String.print_quoted

let fq_parse ?default_program s =
  let s = String.trim s in
  (* rsplit because we might have '/'s in the program name. *)
  match String.rsplit ~by:"/" s with
  | exception Not_found ->
      (match default_program with
      | Some l -> l, s
      | None ->
          Printf.sprintf "Cannot find function %S" s |>
          failwith)
  | p, f -> p, f

let path_of_fq ~suffix fq =
  let pn, fn = fq_parse fq in
  path_of_program ~suffix pn ^"/"^ fn

(* Worker names *)

type worker = [`Worker] t

let worker_ppp_ocaml = t_ppp_ocaml
let worker_ppp_json = t_ppp_json

external worker : string -> worker = "%identity"

let worker_of_fq ?site fq =
  (Option.map_default (fun s -> s ^ ":") "" site) ^ fq

let worker_print = String.print

let worker_parse ?default_site ?default_program s =
  let s = String.trim s in
  let may_add_site p f =
    match String.split ~by:":" p with
    | exception Not_found ->
        default_site, p, f
    | s, p ->
        Some s, p, f
  in
  (* rsplit because we might have '/'s in the program name. *)
  let p, f = fq_parse ?default_program s in
  may_add_site p f

(*$= worker_parse
  (Some (site "TEST"), program "test_prog", func "f") \
    (worker_parse ~default_site:(site "TEST") (worker "test_prog/f"))
*)

(* Base units *)

type base_unit = [`BaseUnit] t

let base_unit_ppp_ocaml = t_ppp_ocaml
let base_unit_ppp_json = t_ppp_json

external base_unit : string -> base_unit = "%identity"
let base_unit_print = String.print
let base_unit_print_quoted = String.print_quoted

(* File paths *)

type path = [`Path] t

let path_ppp_ocaml = t_ppp_ocaml
let path_ppp_json = t_ppp_json

external path : string -> path = "%identity"
let path_print = String.print
let path_print_quoted = String.print_quoted
let path_cat = String.concat "/"

(* Source paths *)

type src_path = [`SrcPath] t

let src_path_ppp_ocaml = t_ppp_ocaml
let src_path_ppp_json = t_ppp_json

let src_path s =
  let rec loop s =
    if s <> "" && s.[0] = '/' then loop (String.lchop s) else s in
  let s = loop (simplified_path s) in
  if s = "" then invalid_arg "empty src_path" ;
  s

let src_path_print = String.print

let src_path_of_program prog =
  (match String.rindex prog '#' with
  | exception Not_found -> prog
  | i -> String.sub prog 0 i) |>
  src_path

let src_path_of_fq fq =
  let prog_name, _func_name = fq_parse fq in
  src_path_of_program prog_name

let src_path_cat = path_cat

(* Host names *)

type host = [`Host] t

let host_ppp_ocaml = t_ppp_ocaml
let host_ppp_json = t_ppp_json

external host : string -> host = "%identity"
let host_print = String.print
let host_print_quoted = String.print_quoted

(* Site names *)

type site = [`Site] t

let site_ppp_ocaml = t_ppp_ocaml
let site_ppp_json = t_ppp_json

let site s =
  if s = "" then failwith "Site names must not be empty"
  else s

let site_print = String.print
let site_print_quoted = String.print_quoted

type site_fq = site * fq
  [@@ppp PPP_OCaml]
  [@@ppp PPP_JSON]

let site_fq_print oc (site, fq) =
  Printf.fprintf oc "%a:%a"
    site_print site
    fq_print fq

(* Service names *)

type service = [`Service] t

let service_ppp_ocaml = t_ppp_ocaml
let service_ppp_json = t_ppp_json

external service : string -> service = "%identity"
let service_print = String.print
let service_print_quoted = String.print_quoted

(* Team names *)

type team = [`Team] t

let team_ppp_ocaml = t_ppp_ocaml
let team_ppp_json = t_ppp_json

let team s =
  (* Not allowed to be empty or have an '/'. *)
  if s = "" || String.contains s '/' then
    invalid_arg "invalid team name" ;
  s

let team_print = String.print


(* Some dedicated colors for those strings: *)

let field_color = blue
let func_color = green
let program_color = green
let rel_program_color = program_color
let expr_color = yellow
let fq_color = func_color
let worker_color = fq_color

type 'a any =
  [< `Field | `Function | `Program | `RelProgram | `FQ | `Worker
   | `BaseUnit | `Url | `Path | `SrcPath | `Host | `Site | `Service ] as 'a

let compare = String.compare
let eq a b = compare a b = 0
let cat = (^)
let length = String.length
let is_empty s = String.length s = 0
let lchop = String.lchop
let starts_with = String.starts_with
let sub = String.sub
