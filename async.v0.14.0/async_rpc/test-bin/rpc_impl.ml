open Core
open Async
open Rpc

(* Generic wrapper over both the Async.Tcp and Netkit backed RPC implementations *)

module Server = struct
  type t =
    | Tcp of (Socket.Address.Inet.t, int) Tcp.Server.t

  let bound_on = function
    | Tcp s -> Tcp.Server.listening_on s
  ;;

  let close = function
    | Tcp s -> Tcp.Server.close s
  ;;
end

type make_transport = Unix.Fd.t -> max_message_size:int -> Async_rpc.Rpc.Transport.t

type t =
  | Async of make_transport

let make_client ?heartbeat_config t host port =
  match t with
  | Async make_transport ->
    Connection.client
      ?heartbeat_config
      ~make_transport
      (Tcp.Where_to_connect.of_host_and_port { host; port })
;;

let with_client ?heartbeat_config t host port f =
  match%bind make_client ?heartbeat_config t host port with
  | Ok conn ->
    let%bind result = f conn in
    let%bind () = Connection.close conn in
    return (Ok result)
  | Error _ as err -> return err
;;

let make_server ?heartbeat_config ?port ~implementations ~initial_connection_state t =
  match t with
  | Async make_transport ->
    let where_to_listen =
      match port with
      | None -> Tcp.Where_to_listen.of_port_chosen_by_os
      | Some port -> Tcp.Where_to_listen.of_port port
    in
    Connection.serve
      ?heartbeat_config
      ~implementations
      ~initial_connection_state:(fun _ x -> initial_connection_state x)
      ~make_transport
      ~where_to_listen
      ()
    >>| fun s -> Server.Tcp s
;;

let spec =
  let open Command.Spec in
  let standard_mt fd ~max_message_size = Transport.of_fd fd ~max_message_size in
  let low_latency_mt fd ~max_message_size =
    Low_latency_transport.create fd ~max_message_size
  in
  let standard _netkit_ifname = Async standard_mt in
  let low_latency _netkit_ifname = Async low_latency_mt in
  let typ =
    Arg_type.of_alist_exn
      [ "standard", standard; "low-latency", low_latency ]
  in
  let transport_flag = optional_with_default standard typ in
  let netkit_ifname_flag = optional_with_default "eth0" string in
  fun () ->
    step (fun main rpc_impl netkit_ifname -> main ~rpc_impl:(rpc_impl netkit_ifname))
    +> flag "-transport" transport_flag ~doc:" RPC transport backend"
    +> flag
         "-netkit-ifname"
         netkit_ifname_flag
         ~doc:" Interface to create a Netkit network on"
;;
