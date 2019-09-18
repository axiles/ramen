(* Service in charge of generating the "info" files.
 *
 * Before it is possible to start a new program, and before the choreographer
 * can create one (or several) worker(s) for this program, and before the
 * supervisor can compile the worker, then the used source file must be
 * pre-compiled (aka. parsed and type-checked) and the result of this pre-
 * compilation saved in an "info" file.
 * The compserver is the daemon in charge of this.
 * Sometimes, the pre-compilation can succeed as soon as a new source files
 * appear. But it also frequently happen that a source program depends on some
 * external program that is not (yet) running, and therefore the pre-compilation
 * must be delayed.
 *
 * The downsides of these delays are several:
 * - that we do not know instantly if the new program fails to type check;
 * - the same source may have to be parsed several times before type-checking
 *   can be attempted.
 * For this later point it would be nice to have either an "ast" file before the
 * "info" or a partial error status with the AST in the info file (TODO).
 *
 * The upside is that we do not need to declare parents output types beforehand.
 *
 * Alternatively, we could also type-check only just before supervisor compiles
 * the worker, but it is much more robust for the types to be known beforehand.
 *)
open Batteries
open RamenLog
open RamenHelpers
open RamenConsts
open RamenSyncHelpers
open RamenSync
module C = RamenConf
module N = RamenName
module ZMQClient = RamenSyncZMQClient

(* Do not generate any executable file, but parse/typecheck new or updated
 * source programs, using the build infrastructure to accept any source format
 * (for now distinguishing them using extension as usual).
 * The only change required from the builder is:
 * - source/target files are read from and written to the config tree instead
 *   of the file system;
 * - instead of using mtime, it must use the md5s;
 * - it must stop before reaching the .x but instead aim for a "/info".
 *)
let start conf ~while_ =
  let topics =
    [ "sites/*/workers/*/worker" ; (* for get_programs *)
      "sources/*" ] in
  let on_set clt k v _uid _mtime =
    let get_parent = RamenCompiler.parent_from_confserver clt in
    let compile path ext =
      (* Program name used to resolve relative names is the location in the
       * source tree: *)
      let program_name = N.program (path : N.src_path :> string) in
      let what = "Compiling "^ (path :> string) in
      log_and_ignore_exceptions ~what
        (RamenMake.build_next conf clt ~while_ get_parent program_name path)
        ext in
    let retry_depending_on new_path =
      Client.iter clt (fun k hv ->
        match k, hv.Client.value with
        | Key.(Sources (path, ext)),
          Value.(SourceInfo { detail =
            Failed { depends_on = Some failed_path ; _ } ; _ })
          when ext <> "info" && failed_path = new_path ->
            compile path ext
        | _ ->
            ()) in
    match k with
    | Key.(Sources (src_path, "info")) ->
        (match v with
        | Value.SourceInfo { detail = Compiled _ ; _ } ->
            (* Whenever a new program is successfully compiled, check for
             * other info that failed to compile because this one was
             * missing and retry them: *)
            retry_depending_on src_path
        | _ ->
            ())
    | Key.(Sources (_, _)) when Value.equal v Value.dummy ->
        (* When the build LockOrCreateKey the new dummy value is seen
         * before the command is acked, thus triggering another build.
         * Cf https://github.com/rixed/ramen/issues/921 *)
        ()
    | Key.(Sources (path, ext)) ->
        assert (ext <> "info") ; (* Case handled above *)
        compile path ext
    | Key.Error _  ->
        (* Errors have been logged already *)
        ()
    | Key.(PerSite (_, PerWorker (_, Worker))) ->
        (* Expected but unused here *)
        ()
    | k ->
        !logger.warning "Irrelevant: %a, %a"
          Key.print k Value.print v in
  let on_new clt k v uid mtime _can_write _can_del _owner _expiry =
    on_set clt k v uid mtime in
  start_sync conf ~while_ ~on_new ~on_set ~topics ~recvtimeo:10.
                  (ZMQClient.process_until ~while_)
