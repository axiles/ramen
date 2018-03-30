let json_content_type = "application/json"
let dot_content_type = "text/vnd.graphviz"
let mermaid_content_type = "text/x-mermaid"
let text_content_type = "text/plain"
let html_content_type = "text/html"
let css_content_type = "text/css"
let svg_content_type = "image/svg+xml"
let js_content_type = "application/javascript"
let ocaml_marshal_type = "application/marshaled.ocaml"
let urlencoded_content_type = "application/x-www-form-urlencoded"
let sqlite_content_type = "application/x-sqlite3"

let in_tuple_count_metric = "in_tuple_count"
let selected_tuple_count_metric = "selected_tuple_count"
let out_tuple_count_metric = "out_tuple_count"
let group_count_metric = "group_count"
let cpu_time_metric = "cpu_time"
let ram_usage_metric = "ram_usage"
let rb_wait_read_metric = "in_sleep"
let rb_wait_write_metric = "out_sleep"
let rb_read_bytes_metric = "in_bytes"
let rb_write_bytes_metric = "out_bytes"

(* Command line strings *)
let start_info = "Start the processes orchestrator."
let compile_info = "Compile each given source file into an executable."
let run_info = "Run one (or several) compiled program(s)."
let kill_info = "Stop a program."
let tail_info = "Display the last outputs of an operation."
let timeseries_info = "Extract a timeseries from an operation."
let timerange_info =
  "Retrieve the available time range of an operation output."
let ps_info = "Display info about running programs."
let default_persist_dir = "/tmp/ramen"
