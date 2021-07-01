Feature: test ramen replay in a simple setting

  We first construct a simple environment to test various replaying
  behavior.
  We will have two source functions (s0 and s1, archived) read by a third one
  (r0, non archived).
  We just put a user config to that effect, and first generate the allocs
  file and reconf the workers so that only the first two are archived,
  and then we generate the stats.
  All this is happening in the Background section, which is therefore
  more involved than usual.

  Later tests check `ramen replay`.

  Background:
    Given the environment variable RAMEN_DEBUG is set
    Given the whole gang is started
    And a file ramen_dir/archivist/v7/config with content
      """
      {
        size_limit = 20000000000;
        retentions = {
          "*:test/s?" => { duration = 600 };
          "*:test/r0" => { duration = 0 };
        }
      }
      """
    And a file test.ramen with content
      """
      define s0 as yield (previous.start |? 0) + 1 as start,
                         (previous.x |? 0) + 2 as x every 1s;
      define s1 as yield (previous.start |? 0) + 1 as start,
                         (previous.x |? 1) + 2 as x every 1s;
      define r0 as select * from s0, s1;
      """
    And test.ramen is compiled
    And program test is running
    # Between the worker appear in the config and an actual process is
    # started, there can be a few seconds. This test being time sensitive, make
    # sure the process is actually started
    And I wait 3 seconds
    And I run ramen with arguments archivist --allocs --reconf
    And I wait 10 seconds
    # To update stats on archived files:
    And I run ramen with arguments gc
    # Given we waited 10s before running the archivist we won't have older
    # data in the archive. Furthermore, we have to wait 5 more seconds in
    # order to have at least 5 lines archived.
    And I wait 5 seconds

#  TODO: ramen confclient key_name to read those values
#  Scenario: Check the allocations from the background situation obey the config.
#    When I run tr with arguments -d '\n[:blank:]' < ramen_dir/archivist/v7/allocs
#    Then tr must mention "","test/r0")=>0"
#    And tr must mention "","test/s0")=>10000000000"
#    And tr must mention "","test/s1")=>10000000000"
#    When I run cat with arguments ramen_dir/workers/out_ref/*/test/s0/*/out_ref
#    Then cat must mention "archive.b"
#    When I run cat with arguments ramen_dir/workers/out_ref/*/test/s1/*/out_ref
#    Then cat must mention "archive.b"
#    When I run cat with arguments ramen_dir/workers/out_ref/*/test/r0/*/out_ref
#    Then cat must not mention "archive.b".

  Scenario: Check we can replay s0 (peace of cake).
    And I run ramen with arguments replay test/s0 --since 10 --until 15
    Then ramen must print between 3 and 5 lines on stdout
    And ramen must exit gracefully.

  Scenario: Check we can also replay r0.
    When I run ramen with arguments replay test/r0 --since 10 --until 15
    Then ramen must print between 5 and 10 lines on stdout
    And ramen must exit gracefully.
