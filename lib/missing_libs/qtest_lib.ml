module Std = struct
  module Runner = struct
    let main tests =
      Async.Thread_safe.block_on_async_exn
        (fun () ->
           Async.Deferred.List.iter tests
            ~f:(fun (name, f) ->
              print_endline name; f ()))
  end
end
