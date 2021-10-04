open Core
open Poly
open Async
open Rpc

module Heartbeat_pipe_test = struct
  let main () =
    let rpc =
      Rpc.create
        ~name:"Heartbeat_pipe_test"
        ~version:1
        ~bin_query:[%bin_type_class: unit]
        ~bin_response:[%bin_type_class: unit]
    in
    let implementations =
      let implementations = [ Rpc.implement rpc (fun () () -> Deferred.unit) ] in
      Implementations.create_exn ~implementations ~on_unknown_rpc:`Raise
    in
    let heartbeat_config =
      Connection.Heartbeat_config.create
        ~timeout:(Time_ns.Span.of_day 1.)
        ~send_every:(Time_ns.Span.of_day 1.)
        ()
    in
    Connection.serve
      ~implementations
      ~heartbeat_config
      ~initial_connection_state:(fun _ _ -> ())
      ~where_to_listen:Tcp.Where_to_listen.of_port_chosen_by_os
      ()
    >>= fun server ->
    let port = Tcp.Server.listening_on server in
    Connection.with_client
      (Tcp.Where_to_connect.of_host_and_port { host = "127.0.0.1"; port })
      ~heartbeat_config
      (fun conn ->
         let c1 = ref 0 in
         Clock.after (sec 1.)
         >>= fun () ->
         Connection.add_heartbeat_callback conn (fun () -> incr c1);
         [%test_eq: int] 0 !c1;
         Clock_ns.after (Time_ns.Span.of_sec 1.)
         >>= fun () ->
         Rpc.dispatch_exn rpc conn ()
         >>= fun () ->
         [%test_eq: int] 1 !c1;
         Tcp.Server.close server
         >>= fun () ->
         (* No more heartbeats now that the server is closed *)
         Connection.add_heartbeat_callback conn (fun () -> assert false);
         Clock_ns.after (Time_ns.Span.of_ms 10.) >>= fun () -> Deferred.unit)
    >>| Result.ok_exn
  ;;

end

module Pipe_closing_test = struct
  type query =
    [ `Do_close
    | `Dont_close
    ]
  [@@deriving bin_io]

  let rpc =
    Pipe_rpc.create
      ()
      ~name:"pipe-closing-test"
      ~version:1
      ~bin_query
      ~bin_response:bin_unit
      ~bin_error:Nothing.bin_t
  ;;

  let main () =
    let implementations =
      Implementations.create_exn
        ~on_unknown_rpc:`Raise
        ~implementations:
          [ Pipe_rpc.implement rpc (fun () query ->
              let pipe = fst (Pipe.create ()) in
              (match query with
               | `Dont_close -> ()
               | `Do_close -> Pipe.close_read pipe);
              return (Ok pipe))
          ]
    in
    Connection.serve
      ()
      ~implementations
      ~initial_connection_state:(fun _ _ -> ())
      ~where_to_listen:Tcp.Where_to_listen.of_port_chosen_by_os
    >>= fun server ->
    let port = Tcp.Server.listening_on server in
    Connection.with_client
      (Tcp.Where_to_connect.of_host_and_port { host = "127.0.0.1"; port })
      (fun conn ->
         Pipe_rpc.dispatch_exn rpc conn `Dont_close
         >>= fun (pipe, id) ->
         Pipe.close_read pipe;
         Pipe_rpc.close_reason id
         >>= fun reason ->
         assert (reason = Closed_locally);
         Pipe_rpc.dispatch_exn rpc conn `Do_close
         >>= fun (pipe, id) ->
         Pipe_rpc.close_reason id
         >>= fun reason ->
         assert (Pipe.is_closed pipe);
         assert (reason = Closed_remotely);
         Pipe_rpc.dispatch_exn rpc conn `Dont_close
         >>= fun (pipe, id) ->
         Connection.close conn
         >>= fun () ->
         Pipe_rpc.close_reason id
         >>= fun reason ->
         assert (Pipe.is_closed pipe);
         assert (
           match reason with
           | Error _ -> true
           | Closed_locally | Closed_remotely -> false);
         Deferred.unit)
    >>| Result.ok_exn
  ;;

end

module Pipe_iter_test = struct
  let rpc =
    Pipe_rpc.create
      ()
      ~name:"dispatch-iter-test"
      ~version:1
      ~bin_query:Time.Span.bin_t
      ~bin_response:Int.bin_t
      ~bin_error:Nothing.bin_t
  ;;

  let main () =
    let implementations =
      Implementations.create_exn
        ~on_unknown_rpc:`Raise
        ~implementations:
          [ Pipe_rpc.implement rpc (fun () query ->
              let r, w = Pipe.create () in
              don't_wait_for
                (Deferred.repeat_until_finished 0 (fun counter ->
                   if counter > 10
                   then (
                     Pipe.close w;
                     return (`Finished ()))
                   else
                     Clock.after query
                     >>| fun () ->
                     Pipe.write_without_pushback_if_open w counter;
                     `Repeat (counter + 1)));
              return (Ok r))
          ]
    in
    Connection.serve
      ()
      ~implementations
      ~initial_connection_state:(fun _ _ -> ())
      ~where_to_listen:Tcp.Where_to_listen.of_port_chosen_by_os
    >>= fun server ->
    let port = Tcp.Server.listening_on server in
    Connection.with_client
      (Tcp.Where_to_connect.of_host_and_port { host = "127.0.0.1"; port })
      (fun conn ->
         let dispatch_exn query f =
           Pipe_rpc.dispatch_iter rpc conn query ~f
           >>| function
           | Error e -> Error.raise e
           | Ok (Error _) -> .
           | Ok (Ok id) -> id
         in
         let next_expected : [ `Update of int | `Closed_remotely ] ref =
           ref (`Update 0)
         in
         let finished = Ivar.create () in
         dispatch_exn Time.Span.millisecond (function
           | Update n ->
             (match !next_expected with
              | `Update n' ->
                assert (n = n');
                next_expected := if n = 10 then `Closed_remotely else `Update (n + 1);
                Continue
              | `Closed_remotely -> assert false)
           | Closed `By_remote_side ->
             (match !next_expected with
              | `Update _ -> assert false
              | `Closed_remotely ->
                Ivar.fill finished ();
                Continue)
           | Closed (`Error e) -> Error.raise e)
         >>= fun (_ : Pipe_rpc.Id.t) ->
         Ivar.read finished
         >>= fun () ->
         let finished = Ivar.create () in
         dispatch_exn Time.Span.second (function
           | Update _ -> assert false
           | Closed `By_remote_side ->
             Ivar.fill finished ();
             Continue
           | Closed (`Error e) -> Error.raise e)
         >>= fun id ->
         Pipe_rpc.abort rpc conn id;
         Ivar.read finished
         >>= fun () ->
         let finished = Ivar.create () in
         dispatch_exn Time.Span.second (function
           | Update _ | Closed `By_remote_side -> assert false
           | Closed (`Error _) ->
             Ivar.fill finished ();
             Continue)
         >>= fun (_ : Pipe_rpc.Id.t) ->
         Connection.close conn >>= fun () -> Ivar.read finished)
    >>| Result.ok_exn
  ;;

end

module Pipe_direct_test = struct
  let rpc =
    Pipe_rpc.create
      ~name:"test-pipe-direct"
      ~version:1
      ~bin_query:[%bin_type_class: [ `Close | `Expect_auto_close of int ]]
      ~bin_response:Int.bin_t
      ~bin_error:Nothing.bin_t
      ()
  ;;

  let main () =
    let auto_close_was_ok : bool Ivar.t array = [| Ivar.create (); Ivar.create () |] in
    let output = List.init 10 ~f:Fn.id in
    let impl =
      Pipe_rpc.implement_direct rpc (fun () action writer ->
        List.iter output ~f:(fun i ->
          match Pipe_rpc.Direct_stream_writer.write_without_pushback writer i with
          | `Ok -> ()
          | `Closed -> assert false);
        (match action with
         | `Close -> Pipe_rpc.Direct_stream_writer.close writer
         | `Expect_auto_close n ->
           let ivar = auto_close_was_ok.(n) in
           upon (Clock.after Time.Span.second) (fun () -> Ivar.fill_if_empty ivar false);
           upon (Pipe_rpc.Direct_stream_writer.closed writer) (fun () ->
             Ivar.fill_if_empty ivar true));
        return (Ok ()))
    in
    let implementations =
      Implementations.create_exn ~implementations:[ impl ] ~on_unknown_rpc:`Raise
    in
    Connection.serve
      ~implementations
      ~initial_connection_state:(fun _ _ -> ())
      ~where_to_listen:Tcp.Where_to_listen.of_port_chosen_by_os
      ()
    >>= fun server ->
    let port = Tcp.Server.listening_on server in
    Connection.with_client
      (Tcp.Where_to_connect.of_host_and_port { host = "127.0.0.1"; port })
      (fun conn ->
         Pipe_rpc.dispatch_exn rpc conn `Close
         >>= fun (pipe, md) ->
         Pipe.to_list pipe
         >>= fun l ->
         [%test_result: int list] l ~expect:output;
         Pipe_rpc.close_reason md
         >>= fun reason ->
         assert (reason = Closed_remotely);
         Pipe_rpc.dispatch_exn rpc conn (`Expect_auto_close 0)
         >>= fun (pipe, md) ->
         Pipe.read_exactly pipe ~num_values:10
         >>= fun result ->
         let l =
           match result with
           | `Eof | `Fewer _ -> assert false
           | `Exactly q -> Queue.to_list q
         in
         Pipe.close_read pipe;
         [%test_result: int list] l ~expect:output;
         Pipe_rpc.close_reason md
         >>= fun reason ->
         assert (reason = Closed_locally);
         Ivar.read auto_close_was_ok.(0)
         >>= fun was_ok ->
         assert was_ok;
         Pipe_rpc.dispatch_exn rpc conn (`Expect_auto_close 1)
         >>= fun (pipe, md) ->
         Connection.close conn
         >>= fun () ->
         Pipe.to_list pipe
         >>= fun l ->
         [%test_result: int list] l ~expect:output;
         Ivar.read auto_close_was_ok.(1)
         >>= fun was_ok ->
         assert was_ok;
         Pipe_rpc.close_reason md
         >>| function
         | Error _ -> ()
         | Closed_locally | Closed_remotely -> assert false)
    >>| Result.ok_exn
  ;;
end

module Rpc_expert_test = struct
  let rpc ~name =
    Rpc.create ~name ~version:0 ~bin_query:bin_string ~bin_response:bin_string
  ;;

  (* names refer to how they're implemented *)
  let unknown_raw_rpc = rpc ~name:"unknown-raw"
  let raw_rpc = rpc ~name:"raw"
  let normal_rpc = rpc ~name:"normal"
  let custom_io_rpc_tag = "custom-io-rpc"
  let custom_io_rpc_version = 0

  let raw_one_way_rpc =
    One_way.create ~name:"raw-one-way" ~version:0 ~bin_msg:String.bin_t
  ;;

  let normal_one_way_rpc =
    One_way.create ~name:"normal-one-way" ~version:0 ~bin_msg:String.bin_t
  ;;

  let the_query = "flimflam"
  let the_response = String.rev the_query

  let main debug ~rpc_impl () =
    let level = if debug then `Debug else `Error in
    let log = Log.create ~level ~output:[ Log.Output.stdout () ] ~on_error:`Raise () in
    let one_way_reader, one_way_writer = Pipe.create () in
    let assert_one_way_rpc_received () =
      Pipe.read one_way_reader
      >>| function
      | `Eof -> assert false
      | `Ok () -> assert (Pipe.is_empty one_way_reader)
    in
    let implementations =
      let handle_raw responder buf ~pos:init_pos ~len =
        let pos_ref = ref init_pos in
        let query = String.bin_read_t buf ~pos_ref in
        [%test_result: string] query ~expect:the_query;
        Log.debug log "query value = %S" query;
        assert (!pos_ref - init_pos = len);
        let new_buf = Bin_prot.Utils.bin_dump String.bin_writer_t the_response in
        ignore
          (Rpc.Expert.Responder.schedule
             responder
             new_buf
             ~pos:0
             ~len:(Bigstring.length new_buf)
           : [ `Connection_closed | `Flushed of unit Deferred.t ])
      in
      let handle_unknown_raw () ~rpc_tag ~version responder buf ~pos ~len =
        Log.debug log "query: %s v%d" rpc_tag version;
        assert (
          rpc_tag = Rpc.name unknown_raw_rpc && version = Rpc.version unknown_raw_rpc);
        try
          handle_raw responder buf ~pos ~len;
          Deferred.unit
        with
        | e ->
          Log.debug log !"got exception: %{Exn#mach}" e;
          Rpc.Expert.Responder.write_error responder (Error.of_exn e);
          Deferred.unit
      in
      Implementations.Expert.create_exn
        ~implementations:
          [ Rpc.implement normal_rpc (fun () query ->
              [%test_result: string] query ~expect:the_query;
              return the_response)
          ; Rpc.Expert.implement' raw_rpc (fun () responder buf ~pos ~len ->
              handle_raw responder buf ~pos ~len;
              Replied)
          ; Rpc.Expert.implement_for_tag_and_version'
              ~rpc_tag:custom_io_rpc_tag
              ~version:custom_io_rpc_version
              (fun () responder buf ~pos ~len ->
                 handle_raw responder buf ~pos ~len;
                 Replied)
          ; One_way.implement normal_one_way_rpc (fun () query ->
              Log.debug log "received one-way RPC message (normal implementation)";
              Log.debug log "message value = %S" query;
              [%test_result: string] query ~expect:the_query;
              Pipe.write_without_pushback one_way_writer ())
          ; One_way.Expert.implement raw_one_way_rpc (fun () buf ~pos ~len ->
              Log.debug log "received one-way RPC message (expert implementation)";
              let pos_ref = ref pos in
              let query = String.bin_read_t buf ~pos_ref in
              Log.debug log "message value = %S" query;
              assert (!pos_ref - pos = len);
              [%test_result: string] query ~expect:the_query;
              Pipe.write_without_pushback one_way_writer ())
          ]
        ~on_unknown_rpc:(`Expert handle_unknown_raw)
    in
    Rpc_impl.make_server
      ~implementations
      ~initial_connection_state:(fun _ -> ())
      rpc_impl
    >>= fun server ->
    let port = Rpc_impl.Server.bound_on server in
    Rpc_impl.with_client rpc_impl "127.0.0.1" port (fun conn ->
      Deferred.List.iter [ unknown_raw_rpc; raw_rpc; normal_rpc ] ~f:(fun rpc ->
        Log.debug log "sending %s query normally" (Rpc.name rpc);
        Rpc.dispatch_exn rpc conn the_query
        >>= fun response ->
        Log.debug log "got response";
        [%test_result: string] response ~expect:the_response;
        let buf = Bin_prot.Utils.bin_dump String.bin_writer_t the_query in
        Log.debug log "sending %s query via Expert interface" (Rpc.name rpc);
        Deferred.create (fun i ->
          ignore
            (Rpc.Expert.schedule_dispatch
               conn
               ~rpc_tag:(Rpc.name rpc)
               ~version:(Rpc.version rpc)
               buf
               ~pos:0
               ~len:(Bigstring.length buf)
               ~handle_error:(fun e -> Ivar.fill i (Error e))
               ~handle_response:(fun buf ~pos ~len ->
                 let pos_ref = ref pos in
                 let response = String.bin_read_t buf ~pos_ref in
                 assert (!pos_ref - pos = len);
                 Ivar.fill i (Ok response);
                 Deferred.unit)
             : [ `Connection_closed | `Flushed of unit Deferred.t ]))
        >>| fun response ->
        Log.debug log "got response";
        [%test_result: string Or_error.t] response ~expect:(Ok the_response))
      >>= fun () ->
      (let buf = Bin_prot.Utils.bin_dump String.bin_writer_t the_query in
       Log.debug log "sending %s query via Expert interface" custom_io_rpc_tag;
       Deferred.create (fun i ->
         ignore
           (Rpc.Expert.schedule_dispatch
              conn
              ~rpc_tag:custom_io_rpc_tag
              ~version:custom_io_rpc_version
              buf
              ~pos:0
              ~len:(Bigstring.length buf)
              ~handle_error:(fun e -> Ivar.fill i (Error e))
              ~handle_response:(fun buf ~pos ~len ->
                let pos_ref = ref pos in
                let response = String.bin_read_t buf ~pos_ref in
                assert (!pos_ref - pos = len);
                Ivar.fill i (Ok response);
                Deferred.unit)
            : [ `Connection_closed | `Flushed of unit Deferred.t ]))
       >>| fun response ->
       Log.debug log "got response";
       [%test_result: string Or_error.t] response ~expect:(Ok the_response))
      >>= fun () ->
      Deferred.List.iter [ raw_one_way_rpc; normal_one_way_rpc ] ~f:(fun rpc ->
        Log.debug log "sending %s query normally" (One_way.name rpc);
        One_way.dispatch_exn rpc conn the_query;
        assert_one_way_rpc_received ()
        >>= fun () ->
        Log.debug log "sending %s query via Expert.dispatch" (One_way.name rpc);
        let buf = Bin_prot.Utils.bin_dump String.bin_writer_t the_query in
        let pos = 0 in
        let len = Bigstring.length buf in
        (match One_way.Expert.dispatch rpc conn buf ~pos ~len with
         | `Ok -> ()
         | `Connection_closed -> assert false);
        assert_one_way_rpc_received ()
        >>= fun () ->
        Log.debug
          log
          "sending %s query via Expert.schedule_dispatch"
          (One_way.name rpc);
        (match One_way.Expert.schedule_dispatch rpc conn buf ~pos ~len with
         | `Flushed f -> f
         | `Connection_closed -> assert false)
        >>= fun () -> assert_one_way_rpc_received ()))
    >>= fun result ->
    Result.ok_exn result;
    Rpc_impl.Server.close server
  ;;

end

module Connection_closing_test = struct
  let one_way_unimplemented =
    One_way.create ~name:"unimplemented" ~version:1 ~bin_msg:bin_unit
  ;;

  let never_returns =
    Rpc.create
      ~name:"never-returns"
      ~version:1
      ~bin_query:bin_unit
      ~bin_response:bin_unit
  ;;

  let never_returns_impl = Rpc.implement never_returns (fun () () -> Deferred.never ())

  let implementations =
    Implementations.create_exn
      ~implementations:[ never_returns_impl ]
      ~on_unknown_rpc:`Continue
  ;;

  let main () =
    let most_recent_server_conn = ref None in
    Connection.serve
      ~implementations
      ~initial_connection_state:(fun _ conn -> most_recent_server_conn := Some conn)
      ~where_to_listen:Tcp.Where_to_listen.of_port_chosen_by_os
      ()
    >>= fun server ->
    let port = Tcp.Server.listening_on server in
    let connect () =
      Connection.client
        (Tcp.Where_to_connect.of_host_and_port { host = "127.0.0.1"; port })
      >>| Result.ok_exn
    in
    let dispatch_never_returns conn =
      let response = Rpc.dispatch never_returns conn () in
      Clock.after Time.Span.second
      >>= fun () ->
      assert (not (Deferred.is_determined response));
      return response
    in
    let check_response_is_error here conn response_deferred =
      Clock.with_timeout Time.Span.second (Connection.close_finished conn)
      >>= function
      | `Timeout ->
        failwithf
          !"%{Source_code_position} timed out waiting for connection to close"
          here
          ()
      | `Result () ->
        Clock.with_timeout Time.Span.second response_deferred
        >>| (function
          | `Timeout ->
            failwithf
              !"%{Source_code_position} timed out waiting for response to be determined"
              here
              ()
          | `Result (Ok ()) ->
            failwithf !"%{Source_code_position} somehow got an ok response for RPC" here ()
          | `Result (Error _) -> ())
    in
    (* Kill the connection after dispatching the RPC. *)
    connect ()
    >>= fun conn ->
    dispatch_never_returns conn
    >>= fun response_deferred ->
    let server_conn = Option.value_exn ~here:[%here] !most_recent_server_conn in
    Connection.close server_conn
    >>= fun () ->
    check_response_is_error [%here] conn response_deferred
    >>= fun () ->
    (* Call an unknown one-way RPC while the connection is open. This causes somewhat
       strange but not problematic behavior -- the server sends back an "unknown RPC"
       message, but the client doesn't have a response handler installed, so it closes the
       connection. *)
    connect ()
    >>= fun conn ->
    dispatch_never_returns conn
    >>= fun response_deferred ->
    One_way.dispatch_exn one_way_unimplemented conn ();
    check_response_is_error [%here] conn response_deferred
  ;;
end

let all_regression_tests =
  Command.async_spec
    ~summary:"run all regression tests"
    Command.Spec.(empty +> flag "debug" no_arg ~doc:"" ++ Rpc_impl.spec ())
    (fun debug ~rpc_impl () ->
       Heartbeat_pipe_test.main ()
       >>= fun () ->
       Pipe_closing_test.main ()
       >>= fun () ->
       Pipe_iter_test.main ()
       >>= fun () ->
       Pipe_direct_test.main ()
       >>= fun () ->
       Rpc_expert_test.main debug ~rpc_impl ()
       >>= fun () -> Connection_closing_test.main ())
;;

let () =
  Command.run
    (Command.group
       ~summary:"Various tests for rpcs"
       [ "regression", all_regression_tests
       ])
;;
