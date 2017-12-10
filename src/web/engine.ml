open Js_of_ocaml
open WebHelpers
open JsHelpers
open RamenHtml

module Html = Dom_html
let doc = Html.window##.document

let clock =
  let seq = ref 0 in
  fun () ->
    incr seq ;
    !seq

(* The non polymorphic part of a parameter: *)
type param_desc =
  { name : string ;
    mutable last_changed : int }

(* All parameters descriptions identified by name *)
let all_params : param_desc Jstable.t = Jstable.create ()

let desc_of_name n =
  Jstable.find all_params (Js.string n) |> Js.Optdef.to_option

(* A parameter is essentially named ref cell *)
type 'a param = { desc : param_desc ; mutable value : 'a }

let make_param name value =
  let desc = { name ; last_changed = clock () } in
  Jstable.add all_params (Js.string name) desc ;
  { desc ; value }
let with_param p f =
  (* [last] must be the current state of the DOM.
   * [with_param] is called only when rebuilding the DOM after a
   * parameter have changed upper toward the root of the vdom (or,
   * as a special case, in the initial populate of the DOM).
   * In that case the elements from the previous call have been
   * suppressed from the DOM already. *)
  (* TODO: we could save the previous vdom generated by f in case
   * p hasn't changed. *)
  let last = 0, group [] in
  Fun { param = p.desc.name ; f = (fun () -> f p.value) ; last = ref last }

(* Parameters *)

let something_changed = ref false
let change p =
  p.desc.last_changed <- clock () ;
  something_changed := true

let chg p v = p.value <- v ; change p

let set p v =
  if v <> p.value then chg p v

let toggle p = chg p (not p.value)

(* Current DOM, starts empty *)

let vdom = ref (Group { subs = [] })

(* Rendering *)

let coercion_motherfucker_can_you_do_it o =
  Js.Opt.get o (fun () -> fail "Cannot coerce")

let rec remove (parent : Dom.element Js.t) child_idx n =
  if n > 0 then (
    Js.Opt.iter (parent##.childNodes##item child_idx) (fun child ->
      print_4 (Js.string ("Removing child_idx="^ string_of_int child_idx ^
                          " of")) parent
              (Js.string ("and "^ string_of_int (n-1) ^" more:")) child ;
      Dom.removeChild parent child) ;
    remove parent child_idx (n - 1)
  )

let root = ref None

let rec set_listener_opt tag (elmt : Dom.element Js.t) action =
  let set_generic_handler elmt action =
    elmt##.onclick := (match action with
      | Some action ->
          Html.handler (fun _ ->
          action "click :)" ;
          resync () ;
          Js._false)
      | None -> Html.no_handler) in
  match tag with
  | "input" ->
    let elmt = Html.CoerceTo.element elmt |>
               coercion_motherfucker_can_you_do_it |>
               Html.CoerceTo.input |>
               coercion_motherfucker_can_you_do_it in
    elmt##.oninput := (match action with
      | Some action ->
        Html.handler (fun _e ->
          action (Js.to_string elmt##.value) ;
          resync () ;
          Js._false)
      | None -> Html.no_handler)
  | "textarea" ->
    let elmt = Html.CoerceTo.element elmt |>
               coercion_motherfucker_can_you_do_it |>
               Html.CoerceTo.textarea |>
               coercion_motherfucker_can_you_do_it in
    elmt##.oninput := (match action with
      | Some action ->
        Html.handler (fun _e ->
          action (Js.to_string elmt##.value) ;
          resync () ;
          Js._false)
      | None -> Html.no_handler)
  | "button" ->
    let elmt = Html.CoerceTo.element elmt |>
               coercion_motherfucker_can_you_do_it |>
               Html.CoerceTo.button |>
               coercion_motherfucker_can_you_do_it in
    elmt##.onclick := (match action with
      | Some action ->
        Html.handler (fun ev ->
          Html.stopPropagation ev ;
          action (Js.to_string elmt##.value) ;
          resync () ;
          Js._false)
      | None -> Html.no_handler)
  | "select" ->
    let elmt = Html.CoerceTo.element elmt |>
               coercion_motherfucker_can_you_do_it |>
               Html.CoerceTo.select |>
               coercion_motherfucker_can_you_do_it in
    elmt##.onchange := (match action with
      | Some action ->
        Html.handler (fun _e ->
          action (Js.to_string elmt##.value) ;
          resync () ;
          Js._false)
      | None -> Html.no_handler)
  | "g" ->
    (* Ohoh, a SVG element! We are lucky since this one inherits from
     * Dom_html.element. *)
    let elmt = Dom_svg.CoerceTo.element elmt |>
               coercion_motherfucker_can_you_do_it |>
               Dom_svg.CoerceTo.g |>
               coercion_motherfucker_can_you_do_it in
    set_generic_handler (elmt :> Html.eventTarget Js.t) action
  | _ ->
    print (Js.string ("No idea how to add an event listener to a "^ tag ^
                      " but I can try")) ;
    (* FIXME: if we put an action on an SVG element this cast to an HTML
     * element will fail. In that case a cast to a Svg_dom.element would
     * work, but that element has no onclick.
     * Maybe we could always try Js.Unsafe.coerce to coerce this into a
     * Html.element in any cases? *)
    let elmt = Html.CoerceTo.element elmt |>
               coercion_motherfucker_can_you_do_it in
    set_generic_handler elmt action

and set_listener tag (elmt : Dom.element Js.t) action =
  set_listener_opt tag elmt (Some action)
and rem_listener tag (elmt : Dom.element Js.t) =
  set_listener_opt tag elmt None

and insert (parent : Dom.element Js.t) child_idx vnode =
  print_2 (Js.string ("Appending "^ string_of_html vnode ^
                      " as child "^ string_of_int child_idx ^" of"))
          parent ;
  match vnode with
  | InView ->
    (* TODO: smooth (https://developer.mozilla.org/en-US/docs/Web/API/Element/scrollIntoView) *)
    (* TODO: make this true/false an InView parameter *)
    (* FIXME: does not seem to work *)
    let parent = Html.CoerceTo.element parent |>
                 coercion_motherfucker_can_you_do_it in
    parent##scrollIntoView Js._false ;
    0
  | Text t ->
    let data = doc##createTextNode (Js.string t) in
    let next = parent##.childNodes##item child_idx in
    Dom.insertBefore parent data next ;
    1
  | Element { tag ; svg ; attrs ; action ; subs ; _ } ->
		let elmt =
      if svg then
        doc##createElementNS Dom_svg.xmlns (Js.string tag)
      else
        doc##createElement (Js.string tag) in
    List.iter (fun (n, v) ->
      elmt##setAttribute (Js.string n) (Js.string v)) attrs ;
    option_may (fun action ->
      let dom_elmt = Js.Unsafe.coerce elmt in
      set_listener tag dom_elmt action) action ;
    let dom_elmt = Js.Unsafe.coerce elmt in
    List.fold_left (fun i sub ->
        i + insert dom_elmt i sub
      ) 0 subs |> ignore ;
    let next = parent##.childNodes##item child_idx in
    Dom.insertBefore parent elmt next ;
    1
  | Fun { param ; f ; last } ->
    (match desc_of_name param with
      Some p ->
        if p.last_changed > fst !last then
          last := clock (), f () ;
        insert parent child_idx (snd !last)
    | None -> 0)
  | Group { subs } ->
    List.fold_left (fun i sub ->
        i + insert parent (child_idx + i) sub
      ) 0 subs

and replace (parent : Dom.element Js.t) child_idx last_vnode vnode =
  match last_vnode, vnode with
  | Text last_t, Text t ->
      if t <> last_t then (
        let elmt = parent##.childNodes##item child_idx |>
                   coercion_motherfucker_can_you_do_it |>
                   Dom.CoerceTo.text |>
                   coercion_motherfucker_can_you_do_it in
        elmt##.data := Js.string t) ;
      1
  | Element { tag = last_tag ; svg = last_svg ; attrs = last_attrs ;
              action = last_action ; subs = last_subs },
    Element { tag ; svg ; attrs ; action ; subs }
    when last_tag = tag && svg = last_svg ->
      let elmt = parent##.childNodes##item child_idx |>
                 coercion_motherfucker_can_you_do_it |>
                 Dom.CoerceTo.element |>
                 coercion_motherfucker_can_you_do_it in
      (* Note: attrs are already sorted *)
      let rec merge a1 a2 =
        match a1, a2 with
        | [], [] -> ()
        | (last_n, last_v)::r1, (n, v)::r2 ->
          (match compare last_n n with
          | 0 ->
            if last_v <> v then
              elmt##setAttribute (Js.string n) (Js.string v) ;
            merge r1 r2
          | -1 ->
            elmt##removeAttribute (Js.string last_n) ;
            merge r1 a2
          | _ ->
            elmt##setAttribute (Js.string n) (Js.string v) ;
            merge a1 r2)
        | (last_n, _)::r1, [] ->
          elmt##removeAttribute (Js.string last_n) ;
          merge r1 a2
        | [], (n, v)::r2 ->
          elmt##setAttribute (Js.string n) (Js.string v) ;
          merge a1 r2
      in
      merge last_attrs attrs ;
      (* We cannot compare old and new actions :-( *)
      option_may (fun _ ->
        rem_listener tag elmt) last_action ;
      option_may (fun action ->
        set_listener tag elmt action) action ;
      replace_list elmt 0 last_subs subs ;
      1
  | Group { subs = last_subs }, Group { subs } ->
      replace_list parent child_idx last_subs subs ;
      flat_length vnode
  | Fun { last = { contents = _, last_vnode } ; _ },
    Fun { last = { contents = last_changed, new_vnode } as last ;
          param ; f } ->
    (match desc_of_name param with
      Some p ->
      if p.last_changed > last_changed then (
        let vnode' = f () in
        last := clock (), vnode' ;
        replace parent child_idx last_vnode vnode'
      ) else
        replace parent child_idx last_vnode new_vnode
    | None -> 0)
  | InView, InView -> 0
  | _ ->
    remove parent child_idx (flat_length last_vnode) ;
    (* Insert will refresh last *)
    insert parent child_idx vnode

and replace_list (parent : Dom.element Js.t) child_idx last_vnodes vnodes =
  (* TODO: A smarter approach is in order:
   *       - Try to detect single node insertions/removals;
   *       - Use node ids as an help. *)
  match last_vnodes, vnodes with
  | [], [] -> ()
  | last_vnode::last_vnodes', vnode::vnodes' ->
    let len = replace parent child_idx last_vnode vnode in
    replace_list parent (child_idx + len) last_vnodes' vnodes'
  | last_vnode::last_vnodes', [] ->
    let len = flat_length last_vnode in
    remove parent child_idx len ;
    replace_list parent child_idx last_vnodes' []
  | [], vnode::vnodes ->
    let len = insert parent child_idx vnode in
    replace_list parent (child_idx + len) [] vnodes

(* Sync just quickly locate nodes where content have changed. From there,
 * we start actually replacing old tree with new one.
 * Only the Fun can produce a different result. is_worthy tells us where to
 * go to have Funs. *)
and sync (parent : Dom.element Js.t) child_idx vnode =
  let ( += ) a b = a := !a + b in
  let rec is_worthy = function
    | Element { subs ; _ } | Group { subs } ->
      (* TODO: a last_touched timestamp in Element that would be back
       * propagated down to rool each time a param is changed? *)
      List.exists is_worthy subs
    | Fun { last ; param ; _ } ->
      (match desc_of_name param with
        Some p ->
        p.last_changed > fst !last || is_worthy (snd !last)
      | None -> false)
    | _ -> false in
  let worthy = is_worthy vnode in
  print (Js.string ("sync vnode="^ string_of_html vnode ^
                    if worthy then " (worthy)" else "")) ;
  match vnode with
  | Element { subs ; _ } ->
    if worthy then (
      (* Follow this path. Child_idx count the children so far. *)
      let parent' = parent##.childNodes##item child_idx |>
                    coercion_motherfucker_can_you_do_it |>
                    Dom.CoerceTo.element |>
                    coercion_motherfucker_can_you_do_it in
      let child_idx = ref 0 in
      List.iter (fun sub ->
          child_idx += sync parent' !child_idx sub
        ) subs) ;
    1
  | Text _ -> 1
  | InView -> 0
  | Group { subs } ->
    if worthy then (
      let i = ref 0 in
      List.iter (fun sub ->
          i += sync parent (child_idx + !i) sub
        ) subs) ;
    flat_length vnode
  | Fun { param ; f ; last } ->
    (match desc_of_name param with
      Some p ->
      let last_changed, last_vnode = !last in
      if p.last_changed > last_changed then (
        let vnode' = f () in
        last := clock (), vnode' ;
        replace parent child_idx last_vnode vnode'
      ) else if worthy then (
        sync parent child_idx last_vnode
      ) else (
        flat_length last_vnode
      )
    | None -> 0)

and resync () =
  print (Js.string "Syncing") ;
  let r =
    match !root with
    | None ->
      let r = Html.getElementById "application" |>
              Js.Unsafe.coerce in
      root := Some r ; r
    | Some r -> r in
  something_changed := false ;
  sync r 0 !vdom |> ignore ;
  (* The refresh of a Fun must not change any parameter that could have been
   * used by an earlier Fun ; we chan check this by checking that the clock
   * did not advance while syncing. *)
  if !something_changed then fail "Rendering is updating parameters!"

(* Each time we update the root, the vdom can differ with the root only
 * at Fun points. Initially though this is not the case, breaking this
 * assumption. That's why we add a Fun at the root, depending on a
 * variable that is never going to change again: *)
let bootup = make_param "initial populate of the DOM" ()

let start nd =
  print (Js.string "starting...") ;
  vdom := with_param bootup (fun () -> nd) ;
  Html.window##.onload := Html.handler (fun _ -> resync () ; Js._false)

(* Ajax *)

let enc s = Js.(to_string (encodeURIComponent (string s)))

(* [times] is how many times we received that message, [time] is when
 * we received it last. *)
type error =
  { mutable time : float ; mutable times : int ;
    message : string ; is_error: bool }
let last_errors = make_param "last errors" []

let now () = (new%js Js.date_now)##valueOf /. 1000.

let install_err_timeouting =
  let err_timeout = 5. and ok_timeout = 1. in
  let timeout_of_err e =
    if e.is_error then err_timeout else ok_timeout in
  let timeout_errs () =
    let now = now () in
    let le, changed =
      List.fold_left (fun (es, changed) e ->
        if e.time +. timeout_of_err e < now then
          es, true
        else
          e::es, changed) ([], false) last_errors.value in
    if changed then (
      chg last_errors le ;
      resync ()) in
  ignore (Html.window##setInterval (Js.wrap_callback timeout_errs) 0_500.)

let ajax action path ?content ?what ?on_done on_ok =
  let req = XmlHttpRequest.create () in
  req##.onreadystatechange := Js.wrap_callback (fun () ->
    if req##.readyState = XmlHttpRequest.DONE then (
      print (Js.string "AJAX query DONE!") ;
      let js = Js._JSON##parse req##.responseText in
      let time = now () in
      option_may apply on_done ;
      let last_error =
        if req##.status <> 200 then (
          print_2 (Js.string "AJAX query failed") js ;
          Some { message = Js.(Unsafe.get js "error" |> to_string) ;
                 times = 1 ; time ; is_error = true }
        ) else (
          on_ok js ;
          option_map (fun message ->
            { times = 1 ; time ; message ; is_error = false }) what) in
      option_may (fun le ->
          match List.find (fun e ->
                  e.is_error = le.is_error &&
                  e.message = le.message) last_errors.value with
          | exception Not_found ->
            chg last_errors (le :: last_errors.value)
          | e ->
            e.time <- le.time ;
            e.times <- e.times + 1 ;
            change last_errors
        ) last_error ;
      resync ())) ;
  req##_open (Js.string action)
             (Js.string path)
             (Js.bool true) ;
  let ct = Js.string Consts.json_content_type in
  req##setRequestHeader (Js.string "Accept") ct ;
  let content = match content with
    | None -> Js.null
    | Some js ->
      req##setRequestHeader (Js.string "Content-type") ct ;
      Js.some (Js._JSON##stringify js) in
  req##send content

let http_get path ?what ?on_done on_ok =
  ajax "GET" path ?what ?on_done on_ok
let http_post path content ?what ?on_done on_ok =
  ajax "POST" path ~content ?what ?on_done on_ok
let http_put path content ?what ?on_done on_ok =
  ajax "PUT" path ~content ?what ?on_done on_ok
let http_del path ?what ?on_done on_ok =
  ajax "DELETE" path ?what ?on_done on_ok

(* Dom library *)

let time_selector ?action duration_param relto_param =
  with_param duration_param (fun cur_dur ->
    let sel label dur =
      if dur = cur_dur then
        button [ clss "selected" ] [ text label ]
      else
        button ~action:(fun _ ->
            set duration_param dur ;
            option_may apply action)
          [ clss "actionable" ] [ text label ] in
    div
      [ clss "chart-buttons" ]
      [ sel "last 10m" 600. ;
        sel "last hour" 3600. ;
        sel "last 3h" (3. *. 3600.) ;
        sel "last 8h" (8. *. 3600.) ;
        sel "last day" (24. *. 3600.) ;
        let action _ =
          toggle relto_param ;
          option_may apply action in
        with_param relto_param (function
          | true ->
              button ~action
                [ clss "actionable selected" ]
                [ text "rel.to event time" ]
          | false ->
              button ~action
                [ clss "actionable" ]
                [ text "rel.to event time" ]) ])
