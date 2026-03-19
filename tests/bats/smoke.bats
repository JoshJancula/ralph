#!/usr/bin/env bats

@test "bats runs" {
  run true
  [ "$status" -eq 0 ]
}
