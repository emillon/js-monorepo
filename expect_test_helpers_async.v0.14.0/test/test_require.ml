open! Core
open! Async
open! Import

let%expect_test "[require]" =
  require [%here] true;
  let%bind () = [%expect {|
    |}] in
  require [%here] false ~cr:CR_someday;
  let%bind () =
    [%expect
      {|
        (* CR-someday require-failed: expect_test_helpers_async.v0.14.0/test/test_require.ml:LINE:COL.
           Do not 'X' this CR; instead make the required property true,
           which will make the CR disappear.  For more information, see
           [Expect_test_helpers_base.require]. *)
    |}]
  in
  require
    [%here]
    false
    ~cr:Comment
    ~if_false_then_print_s:(lazy [%sexp "additional-info"]);
  let%bind () =
    [%expect
      {|
    (* require-failed: expect_test_helpers_async.v0.14.0/test/test_require.ml:LINE:COL. *)
    additional-info |}]
  in
  return ()
;;
