(* A small service turning replay requests into actual replays: *)
open Batteries

open RamenLog
open RamenHelpersNoLog
open RamenHelpers
open RamenSyncHelpers
open RamenSync
module C = RamenConf
module CltCmd = Sync_client_cmd.DessserGen
module Default = RamenConstsDefault
module N = RamenName
module ZMQClient = RamenSyncZMQClient
module Export = RamenExport
module Replay = RamenReplay

let create_replay conf session resp_key target since until explain =
  let fq =
    N.fq_of_program target.Fq_function_name.DessserGen.program
                    target.function_ in
  let clt = option_get "create_replay" __LOC__ session.ZMQClient.clt in
  let _prog, prog_name, func = function_of_fq clt fq in
  let stats = Export.replay_stats clt in
  match Replay.create conf stats ~resp_key
                      (Some target.Fq_function_name.DessserGen.site)
                      prog_name func since until with
  | exception Replay.NoData ->
      !logger.warning "Not enough data to replay %a since %a until %a"
        RamenSync.Value.site_fq_print target
        print_as_date since
        print_as_date until ;
      (* Terminate the replay at once: *)
      !logger.debug "Deleting publishing key %a" Key.print resp_key ;
      ZMQClient.(send_cmd session (CltCmd.DelKey resp_key))
  | replay ->
      let v = Value.Replay replay in
      if explain then (
        ZMQClient.(send_cmd session (CltCmd.SetKey (resp_key, v))) ;
        ZMQClient.(send_cmd session (CltCmd.DelKey resp_key))
      ) else (
        let k = Key.Replays replay.channel in
        ZMQClient.(send_cmd session (CltCmd.NewKey (k, v, 0., false)))
      )

let start conf ~while_ =
  let topics =
    "replay_requests" :: Export.replay_topics in
  let synced = ref false in
  let on_synced _session = synced := true in
  let on_set session k v _uid _mtime =
    match k, v with
    | Key.ReplayRequests,
      Value.ReplayRequest { target ; since ; until ; explain ; resp_key } ->
        (* Be wary of replay requests found at startup that could cause
         * crashloop, better delete them *)
        if !synced then (
          let what =
            Printf.sprintf2 "creating replay for resp_key %a"
              Key.print resp_key in
          log_and_ignore_exceptions ~what
            (create_replay conf session resp_key target since until) explain
        ) else (
          !logger.warning "Deleting pending replay request %a"
            Value.print v ;
          ZMQClient.(send_cmd session (CltCmd.DelKey k))
        )
    | _ -> () in
  let on_new session k v uid mtime _can_write _can_del _owner _expiry =
    on_set session k v uid mtime in
  start_sync conf ~while_ ~on_set ~on_new ~topics ~recvtimeo:1. ~on_synced
             ~sesstimeo:Default.sync_long_sessions_timeout
             (ZMQClient.process_until ~while_)
