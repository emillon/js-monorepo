open! Base

(* Printing the raw grammar should be a last resort when there is no better way to test
   the ppx (e.g., [@@deriving_inline _]). The output is illegible and fragile. *)

let test _raw_grammar =
  ()
;;

let%expect_test "polymorphic" =
  test [%sexp_grammar: < for_all : 'k 'v. ('k * 'v) list > ];
  [%expect
    {| |}]
;;

let%expect_test "primitive" =
  test [%sexp_grammar: int];
  [%expect
    {| |}]
;;

let%expect_test "application of polymorphic type constructor" =
  test [%sexp_grammar: int list];
  [%expect
    {| |}]
;;

let%expect_test "arrow type / original polymorphic type syntax" =
  test [%sexp_grammar: 'k -> 'v -> ('k * 'v) list];
  [%expect
    {| |}]
;;
