(* Collector for collectd binary protocol (as described in
 * https://collectd.org/wiki/index.php/Binary_protocol).
 *
 * Collectd sends one (or several) UDP datagrams every X seconds (usually
 * X=10s).  Messages contains individual metrics that are composed of a time, a
 * hostname, a metric name (composed of plugin name, instance name, etc) and
 * one (or sometime several) numerical values.  We map this into a tuple which
 * type is known. But since there is no boundary in between different
 * collections and no guarantee that the time of all closely related
 * measurements are strictly the same, what we do is accumulate every metric
 * until the time changes significantly (more than, say, 5s) or we encounter a
 * metric name we already have.  Only then do we output a tuple. *)
open Batteries
open RamenLog
open RamenHelpers
open RamenTypes
open RamenTuple
open RamenNullable

(* <blink>DO NOT ALTER</blink> this record without also updating
 * wrap_collectd_decode in wrap_collectd.c and tuple_typ below! *)
type collectd_metric =
  string (* host *) * float (* start *) *
  string nullable (* plugin name *) * string nullable (* plugin instance *) *
  string nullable (* type name (whatever that means) *) *
  string nullable (* type instance *) *
  (* And the values (up to 5: *)
  float * float nullable * float nullable * float nullable * float nullable

let tuple_typ =
  [ { name = RamenName.field_of_string "host" ; typ = { structure = TString ; nullable = false } ; units = None ; doc = "" ; aggr = None } ;
    { name = RamenName.field_of_string "start" ; typ = { structure = TFloat ; nullable = false } ; units = Some RamenUnits.seconds_since_epoch ; doc = "" ; aggr = None } ;
    { name = RamenName.field_of_string "plugin" ; typ = { structure = TString ; nullable = true } ; units = None ; doc = "" ; aggr = None } ;
    { name = RamenName.field_of_string "instance" ; typ = { structure = TString ; nullable = true } ; units = None ; doc = "" ; aggr = None } ;
    { name = RamenName.field_of_string "type_name" ; typ = { structure = TString ; nullable = true } ; units = None ; doc = "" ; aggr = None } ;
    { name = RamenName.field_of_string "type_instance" ; typ = { structure = TString ; nullable = true } ; units = None ; doc = "" ; aggr = None } ;
    { name = RamenName.field_of_string "value" ; typ = { structure = TFloat ; nullable = false } ; units = None ; doc = "" ; aggr = None } ;
    { name = RamenName.field_of_string "value2" ; typ = { structure = TFloat ; nullable = true } ; units = None ; doc = "" ; aggr = None } ;
    { name = RamenName.field_of_string "value3" ; typ = { structure = TFloat ; nullable = true } ; units = None ; doc = "" ; aggr = None } ;
    { name = RamenName.field_of_string "value4" ; typ = { structure = TFloat ; nullable = true } ; units = None ; doc = "" ; aggr = None } ;
    { name = RamenName.field_of_string "value5" ; typ = { structure = TFloat ; nullable = true } ; units = None ; doc = "" ; aggr = None } ]

let event_time =
  let open RamenEventTime in
  Some ((RamenName.field_of_string "start", ref OutputField, 1.),
        DurationConst 0.)

let factors =
  [ RamenName.field_of_string "plugin" ;
    RamenName.field_of_string "type_instance" ;
    RamenName.field_of_string "instance" ]

external decode : Bytes.t -> int -> collectd_metric array = "wrap_collectd_decode"

let collector ~inet_addr ~port ?while_ k =
  (* Listen to incoming UDP datagrams on given port: *)
  let serve ?sender buffer recv_len =
    !logger.debug "Received %d bytes from collectd @ %s"
      recv_len
      (match sender with None -> "??" |
       Some ip -> Unix.string_of_inet_addr ip) ;
    decode buffer recv_len |>
    Array.iter k
  in
  (* collectd current network.c buffer is 1452 bytes: *)
  udp_server ~buffer_size:1500 ~inet_addr ~port ?while_ serve

let test ?(port=25826) () =
  init_logger Normal ;
  let display_tuple _t = () in
  collector ~inet_addr:Unix.inet_addr_any ~port display_tuple
