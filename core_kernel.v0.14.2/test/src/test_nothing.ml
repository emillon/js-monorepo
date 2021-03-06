open! Core_kernel
open! Import

let%expect_test "t_of_sexp" =
  require_does_raise [%here] (fun () -> Nothing.t_of_sexp (Sexp.List []));
  [%expect
    {|
    (Of_sexp_error
     "Base.Nothing.t_of_sexp: trying to convert an empty type"
     (invalid_sexp ())) |}]
;;

let%test_module "Stable.V1" =
  (module struct
    module Nothing = Nothing.Stable.V1

    let%expect_test "t_of_sexp" =
      require_does_raise [%here] (fun () -> Nothing.t_of_sexp (Sexp.List []));
      [%expect
        {|
        (Of_sexp_error
         "core_kernel.v0.14.2/src/nothing.ml.Stable.V1.t_of_sexp: trying to convert an empty type"
         (invalid_sexp ())) |}]
    ;;
  end)
;;
