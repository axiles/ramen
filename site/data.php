<?
$info_pages = [
  'index.html' => [
    'title' => 'Overview' ],

  'download.html' => [
    'title' => 'Downloading',
    'description' => 'Downloading prepackaged binaries or docker images' ],

  'build.html' => [
    'title' => 'Building',
    'description' => 'Building from sources' ],

  'tutorials.html' => [
    'title' => 'Tutorials',
    'sub_pages' => [
      'tutorials/monitoring_quick.html' => [
        'title' => 'Network monitoring in 15 minutes' ] ] ],

  'design.html' => [
    'title' => 'Design',
    'sub_pages' => [
      'requirements.html' => [
        'title' => 'Initial Requirements' ],
      'programs.html' => [
        'title' => 'Functions, programs and workers' ],
      'communication.html' => [
        'title' => 'Messages and message passing' ],
      'archival.html' => [
        'title' => 'Archival and replay' ] ] ],

  'roadmap.html' => [
    'title' => 'Roadmap' ],

  'man.html' => [
    'title' => 'Command line reference',
    'sub_pages' => [
      'man.html#compiling' => [
        'title' => 'Compiling programs',
        'man_pages' => [
          'compile.html' => [
            'title' => 'Compile a Ramen program' ] ] ],
      'man.html#running' => [
        'title' => 'Running programs',
        'man_pages' => [
          'supervisor.html' => [
            'title' => 'The daemon that runs all functions' ],
          'run.html' => [
            'title' => 'Starting a program' ],
          'kill.html' => [
            'title' => 'Stopping a program' ],
          'ps.html' => [
            'title' => 'See which programs/functions are running' ] ] ],
      'man.html#querying' => [
        'title' => 'Retrieving data',
        'man_pages' => [
          'tail.html' => [
            'title' => 'Print some function output' ],
          'timeseries.html' => [
            'title' => 'Print a fixed time-step time series out of some columns' ],
          'replay.html' => [
            'title' => 'Like tail, but reconstruct the data that are not available from archived data' ],
          'httpd.html' => [
            'title' => 'HTTP daemon to output time series, impersonating Graphite' ] ] ],
      'man.html#alerting' => [
        'title' => 'Alerting',
        'man_pages' => [
          'alerter.html' => [
            'title' => 'The daemon responsible for routing and sending alerts' ],
          'notify.html' => [
            'title' => 'Inject a notification from the command line' ] ] ],
      'man.html#maintenance' => [
        'title' => 'Maintenance',
        'man_pages' => [
          'gc.html' => [
            'title' => 'Garbage collect old archives' ],
          'links.html' => [
            'title' => 'Print the state of ring buffers' ],
          'ringbuf.html' => [
            'title' => 'Print some information about a ring buffer' ],
          'archivist.html' => [
            'title' => 'Daemon that periodically reallocate storage space' ],
          'stats.html' => [
            'title' => 'Print some internal instrumentation data' ],
          'variants.html' => [
            'title' => 'Print some internal experimentation settings' ] ] ],
      'man.html#tests' => [
        'title' => 'Tests',
        'man_pages' => [
          'test.html' => [
            'title' => 'Test the behavior of a set of prograns' ] ] ] ] ],

  'language_reference.html' => [
    'title' => 'Language reference',
    'sub_pages' => [
      'language_reference.html#syntax' => [
        'title' => 'Basic Syntax' ],
      'language_reference.html#values' => [
        'title' => 'Values' ],
      'language_reference.html#expressions' => [
        'title' => 'Expressions' ],
      'language_reference.html#functions' => [
        'title' => 'Functions' ],
      'language_reference.html#programs' => [
        'title' => 'Programs' ],
      'language_reference.html#experiments' => [
        'title' => 'Experiments' ],
    ] ],

  'glossary.html' => [
    'title' => 'Glossary' ],

  'blog.html' => [
    'title' => 'Blog posts',
    'description' => 'Blog about various aspects of Ramen design',
    'sub_pages' => [
      'blog/2018-12.html' => [
        'date' => 'December 2018',
        'title' => 'One-liners' ],
      'blog/2019-01.html' => [
        'date' => 'January 2019',
        'title' => 'Projection of deep compound types' ],
      'blog/2019-02.html' => [
        'date' => 'February 2019',
        'title' => 'Benchmark against KSQL' ],
      'blog/2019-03.html' => [
        'date' => 'Mars 2019',
        'title' => 'One degree of scale' ],
      'blog/2019-05.html' => [
        'date' => 'May 2019',
        'title' => 'Who need two different message queues?' ],
      'blog/2019-07.html' => [
        'date' => 'July 2019',
        'title' => 'Does C++ devs worth more than web devs?' ],
      'blog/2019-12.html' => [
        'date' => 'December 2019',
        'title' => 'Walk through deep field selection' ],
      'blog/2019-12_.html' => [
        'date' => 'December 2019',
        'title' => 'Walk through replays' ],
      'blog/2022-02.html' => [
        'date' => 'February 2022',
        'title' => 'What happened those last two years?' ],
    ] ],
];
?>
