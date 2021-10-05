(lang dune 2.9)

(name js-monorepo)

(generate_opam_files true)

(package
 (name js-monorepo)
 (depends
  expect_test_helpers_async
  expect_test_helpers_core
  core_bench
  qtest
  re2
  ounit2))
