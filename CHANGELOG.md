### 0.9.0 [February 20th, 2012]
* Added manual synchronous flushing command
* Fixed bug with data dropping on short-lived forks

### 0.8.3 [February 9th, 2012]
* Removing symbol to proc use for compatibility with older version of Ruby

### 0.8.2 [January 17, 2012]
* Fixing data loss issue when collector was not responding appropriately

### 0.8.1 [January 13, 2012]
* Event timing works when timed events throw exceptions

### 0.8.0 [January 10, 2012]
* Initial support for timing events.

### 0.7.2 [January 5, 2012]
* Deploy durations tracking fixed.

### 0.7.1 [January 5, 2012]
* Support for exponentially encoded float values

### 0.7 [January 2, 2012]
* .notice added to API to allow tracking project-wide events on graphs
* Added Capistrano recipe contributed by [janxious] from (https://github.com/expectedbehavior/)
* Removed Rack middleware
* Logs to STDERR instead of /dev/null
* Synchronous mode can be specified in agent initialization contributed by [janxious] from (https://github.com/expectedbehavior/)
* Added CHANGELOG :)

### 0.6.1 [December 16, 2011]
* Documentation cleanup

### 0.6 [December 13, 2011]
* Synchronous agent support to allow blocking send of metrics
* Message buffer increased to 5000
* Code cleanup

### 0.5.1 [December 12, 2011]
* instrument_server moved to instrumental_tools gem (https://github.com/fastestforward/instrumental_tools)

### 0.5 [December 9, 2011]
* Allow negative numbers to be submitted
* agent logger now can be configured per instance
* Better RSpec formatting for tests

### 0.4 [December 1, 2011]
* Support reconnecting on fork() for forking servers like Passenger

### 0.3 [November 17, 2011]
* Support for test_mode on agent to cause submitted metrics to be thrown away when it reaches Instrumental servers
* Fix version not being sent in agent hello
* Exceptions in agent get swallowed and reported to logger

### 0.2 [November 15, 2011]
* Refactored agent to use TCPSocket instead of EventMachine

### 0.1.6 [November 14, 2011]
* Middleware doesn't automatically inject itself into Rack middleware stack

### 0.1.5 [November 1, 2011]
* Documentation changes

### 0.1.4 [November 1, 2011]
* Documentation changes

### 0.1.3 [October 31, 2011]
* Rename the watch_server command to instrument_server
* Documentation changes

### 0.1.2 [October 30, 2011]
* Add enabled flag to control agent use in test/non-development environments
* watch_server runs every 10s

### 0.1.1 [October 27, 2011]
* Linux support for watch_server
* Documentation changes

### 0.1 [October 27, 2011]
* Initial version
