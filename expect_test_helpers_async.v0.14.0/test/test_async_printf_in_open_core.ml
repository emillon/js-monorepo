open! Core

(* No [open! Import] because we want to be very explicit about the environment. *)

let%expect_test "" =
  Expect_test_helpers_core.require ~cr:Comment [%here] false;
  [%expect
    {|
    (* require-failed: expect_test_helpers_async.v0.14.0/test/test_async_printf_in_open_core.ml:LINE:COL. *) |}]
;;
