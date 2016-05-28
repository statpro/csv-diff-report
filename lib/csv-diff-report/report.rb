require 'csv-diff-report/excel'
require 'csv-diff-report/html'
require 'csv-diff-report/text'


class CSVDiff

    # Defines a class for generating diff reports using CSVDiff.
    #
    # A diff report may contain multiple file diffs, and can be output as either an
    # XLSX spreadsheet document, or an HTML file.
    class Report

        include Excel
        include Html
        include Text


        # Instantiate a new diff report object. Takes an optional block callback
        # to use for handling the output generated by the diff process. If no
        # callback is supplied, this output will be sent to the console using
        # ColorConsole.
        #
        # @yield [*out] If supplied, the block passed to this method will be
        #   called for each line of text to be output. The argument to the block
        #   will be an array of text chunks, each of which may be accompanied by
        #   optional foreground and background colours.
        def initialize(&block)
            @diffs = []
            @echo_handler = block
        end


        def echo(*args)
            if @echo_handler
                @echo_handler.call(*args)
            else
                args.each do |out|
                    Console.write(*out)
                end
                Console.puts
            end
        end


        # Add a CSVDiff object to this report.
        def <<(diff)
            if diff.is_a?(CSVDiff)
                @diffs << diff
                unless @left
                    @left = Pathname.new(diff.left.path)
                    @right = Pathname.new(diff.right.path)
                end
                diff.diff_warnings.each{ |warn| echo [warn, :yellow] }
                out = []
                out << ["Found #{diff.diffs.size} differences"]
                diff.summary.each_with_index.map do |pair, i|
                    out << [i == 0 ? ": " : ", "]
                    k, v = pair
                    color = case k
                            when 'Add' then :light_green
                            when 'Delete' then :red
                            when 'Update' then :cyan
                            when 'Move' then :light_magenta
                            when 'Warning' then :yellow
                            end
                    out << ["#{v} #{k}s", color]
                end
                echo(*out)
            else
                raise ArgumentError, "Only CSVDiff objects can be added to a CSVDiff::Report"
            end
        end


        # Add a diff to the diff report.
        #
        # @param options [Hash] Options to be passed to the diff process.
        def diff(left, right, options = {})
            @left = Pathname.new(left)
            @right = Pathname.new(right)
            if @left.file? && @right.file?
                echo "Performing file diff:"
                echo "  From File:    #{@left}"
                echo "  To File:      #{@right}"
                opt_file = load_opt_file(@left.dirname)
                diff_file(@left.to_s, @right.to_s, options, opt_file)
            elsif @left.directory? && @right.directory?
                echo "Performing directory diff:"
                echo "  From directory:  #{@left}"
                echo "  To directory:    #{@right}"
                opt_file = load_opt_file(@left)
                if fts = options[:file_types]
                    file_types = find_matching_file_types(fts, opt_file)
                    file_types.each do |file_type|
                        hsh = opt_file[:file_types][file_type]
                        ft_opts = options.merge(hsh)
                        diff_dir(@left, @right, ft_opts, opt_file)
                    end
                else
                    diff_dir(@left, @right, options, opt_file)
                end
            else
                raise ArgumentError, "Left and right must both exist and be files or directories"
            end
        end


        # Saves a diff report to +path+ in +format+.
        #
        # @param path [String] The path to the output report.
        # @param format [Symbol] The output format for the report; one of :html or
        #   :xlsx.
        def output(path, format = :html)
            path = case
            when format.to_s =~ /^xlsx?$/i || File.extname(path) =~ /xlsx?$/i
                xl_output(path)
            when format.to_s =~ /^html$/i || File.extname(path) =~ /html$/i
                html_output(path)
            when format.to_s =~ /^(te?xt|csv)$/i || File.extname(path) =~ /(csv|txt)$/i
                text_output(path)
            else
                raise ArgumentError, "Unrecognised output format: #{format}"
            end
            echo "Diff report saved to '#{path}'"
        end


        private


        # Loads an options file from +dir+
        def load_opt_file(dir)
            opt_path = Pathname(dir + '.csvdiff')
            opt_path = Pathname('.csvdiff') unless opt_path.exist?
            if opt_path.exist?
                echo "Loading options from '#{opt_path}'"
                opt_file = YAML.load(IO.read(opt_path))
                symbolize_keys(opt_file)
            end
        end


        # Convert keys in hashes to lower-case symbols for consistency
        def symbolize_keys(hsh)
            Hash[hsh.map{ |k, v| [k.to_s.downcase.intern, v.is_a?(Hash) ?
                symbolize_keys(v) : v] }]
        end


        def titleize(sym)
            sym.to_s.gsub(/_/, ' ').gsub(/\b([a-z])/) { $1.upcase }
        end


        # Locates the file types in +opt_file+ that match the +file_types+ list of
        # file type names or patterns
        def find_matching_file_types(file_types, opt_file)
            matched_fts = []
            if known_fts = opt_file && opt_file[:file_types] && opt_file[:file_types].keys
                file_types.each do |ft|
                    re = Regexp.new(ft.gsub('.', '\.').gsub('?', '.').gsub('*', '.*'), true)
                    matches = known_fts.select{ |file_type| file_type.to_s =~ re }
                    if matches.size > 0
                        matched_fts.concat(matches)
                    else
                        echo ["No file type matching '#{ft}' defined in .csvdiff", :yellow]
                        echo ["Known file types are: #{opt_file[:file_types].keys.join(', ')}", :yellow]
                    end
                end
            else
                if opt_file
                    echo ["No file types are defined in .csvdiff", :yellow]
                else
                    echo ["The file_types option can only be used when a " +
                        ".csvdiff is present in the LEFT or current directory", :yellow]
                end
            end
            matched_fts.uniq
        end


        # Diff files that exist in both +left+ and +right+ directories.
        def diff_dir(left, right, options, opt_file)
            pattern = Pathname(options[:pattern] || '*')
            exclude = options[:exclude]

            echo "  Include Pattern: #{pattern}"
            echo "  Exclude Pattern: #{exclude}" if exclude

            left_files = Dir[(left + pattern).to_s.gsub('\\', '/')].sort
            excludes = exclude ? Dir[(left + exclude).to_s.gsub('\\', '/')] : []
            (left_files - excludes).each_with_index do |file, i|
                right_file = right + File.basename(file)
                if right_file.file?
                    diff_file(file, right_file.to_s, options, opt_file)
                else
                    echo ["Skipping file '#{File.basename(file)}', as there is " +
                        "no corresponding TO file", :yellow]
                end
            end
        end


        # Diff two files, and add the results to the diff report.
        #
        # @param left [String] The path to the left file
        # @param right [String] The path to the right file
        # @param options [Hash] The options to be passed to CSVDiff.
        def diff_file(left, right, options, opt_file)
            settings = find_file_type_settings(left, opt_file)
            if settings[:ignore]
                echo "Ignoring file #{left}"
                return
            end
            options = settings.merge(options)
            from = open_source(left, :from, options)
            to = open_source(right, :to, options)
            diff = CSVDiff.new(from, to, options)
            self << diff
            diff
        end


        # Locates any file type settings for +left+ in the +opt_file+ hash.
        def find_file_type_settings(left, opt_file)
            left = Pathname(left.gsub('\\', '/'))
            settings = opt_file && opt_file[:defaults] || {}
            opt_file && opt_file[:file_types] && opt_file[:file_types].each do |file_type, hsh|
                unless hsh[:pattern]
                    echo ["Invalid setting for file_type #{file_type} in .csvdiff; " +
                        "missing a 'pattern' key to use to match files", :yellow]
                    hsh[:pattern] = '-'
                end
                next if hsh[:pattern] == '-'
                unless hsh[:matched_files]
                    hsh[:matched_files] = Dir[(left.dirname + hsh[:pattern]).to_s.gsub('\\', '/')]
                    hsh[:matched_files] -= Dir[(left.dirname + hsh[:exclude]).to_s.gsub('\\', '/')] if hsh[:exclude]
                end
                if hsh[:matched_files].include?(left.to_s)
                    settings.merge!(hsh)
                    [:pattern, :exclude, :matched_files].each{ |k| settings.delete(k) }
                    break
                end
            end
            settings
        end


        # Opens a source file.
        #
        # @param src [String] A path to the file to be opened.
        # @param options [Hash] An options hash to be passed to CSVSource.
        def open_source(src, left_right, options)
            out = ["Opening #{left_right.to_s.upcase} file '#{File.basename(src)}'..."]
            csv_src = CSVDiff::CSVSource.new(src.to_s, options)
            out << ["  #{csv_src.lines.size} lines read", :white]
            echo(*out)
            csv_src.warnings.each{ |warn| echo [warn, :yellow] }
            csv_src
        end

    end

end
