module Overcommit::Hook::PreCommit
  # Runs `jscs` (JavaScript Code Style Checker) against any modified JavaScript
  # files.
  #
  # @see http://jscs.info/
  class Jscs < Base
    def run
      result = execute(command, args: applicable_files)
      return :pass if result.success?

      if result.status == 1
        # No configuration was found
        return :warn, result.stderr.chomp
      end

      # example message:
      #   path/to/file.js: line 7, col 0, ruleName: Error message
      extract_messages(
        result.stdout.split("\n"),
        /^(?<file>(?:\w:)?[^:]+):[^\d]+(?<line>\d+)/,
      )
    end
  end
end
