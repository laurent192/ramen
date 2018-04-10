# Some of the steps perform a change while others check that some changes have
# happened. Steps which perform a change are descriptions of the desired state,
# while steps that check uses the modal "must".

Given /(.*) must be in the path/ do |executable|
  found = ENV["PATH"].split(":").any? {|p| File.executable? (p+'/ramen')}
  expect(found).to eq true
end

Given /the environment variable (.*) is set(?: to (.*))?/ \
do |envvar, opt_val|
  if ENV[envvar].nil? then
    val =
      if opt_val.nil?
        case envvar
          when /RAMEN_BUNDLE_DIR/
            ENV['HOME'] + '/share/src/ramen/bundle'
          else
            fail(StandardError.new("No idea what to set #{envvar} to"))
        end
      else
        opt_val
      end
    ENV[envvar] = val
  end
end

Given /the environment variable (.*) is not (?:set|defined)/ do |envvar|
  ENV[envvar] = nil
end

Given /the environment variable (.*) must (not )?be (?:set|defined)/ \
do |envvar, unset|
  if unset then
    expect(ENV[envvar]).to equal nil
  else
    expect(ENV[envvar]).to be_truthy
  end
end

When /I run (.*) with no argument/ do |executable|
  @output ||= {}
  @output[executable] = exec(executable, '')
end

When /I run (.*) with arguments? (.*)/ do |executable, args|
  @output ||= {}
  @output[executable] = exec(executable, args)
  #puts @output[executable]['stdout']
  #puts @output[executable]['stderr']
end

Then /(.*) must print (.*) lines? on (std(?:out|err))/ \
do |executable, quantity, out|
  filter = Filter.new(quantity)
  filter.check(@output[executable][out].lines.count)
end

Then /(.*) must exit with status (.*)(\d)/ do |executable, cmp, status|
  exp = status.to_i
  got = @output[executable]['status']
  case cmp
    when ''
      expect(got).to equal exp
    when /not|different from/
      expect(got).not_to equal exp
  end
end

Given /a file (.*) with content/ do |file_name, file_content|
  file_name = $tmp_dir + '/' + file_name
  FileUtils.mkdir_p File.dirname(file_name)
  File.open(file_name, "w+") do |f| f.write file_content end
end

Given /no files? (ending with|starting with|named) (.*) (?:is|are) present in (.*)/ \
do |condition, like, dir|
  Dir[$tmp_dir +'/' + dir + '/*'].each do |f|
    File.delete(f) if
      case condition
        when /ending with/
          f.end_with? like
        when /starting with/
          f.star_with? like
        when /named/
          f == like
      end
  end
end

Then /(?:an? )?(executable )?files? (.*) must exist/ \
do |opt_file_type, files|
  files.list_split.each do |f|
    expect(File.exist? f).to be true
    expect(
      case opt_file_type
        when /executable/
          File.executable? f
        when /readable/
          File.readable? f
        when /writable/
          File.writable? f
      end).to be true
  end
end

Then /(.*) must produce( executables?)? files? (.*)/ \
do |executable, opt_file_type, files|
  step "#{executable} must print a few lines on stdout"
  step "#{executable} must print no line on stderr"
  step "#{executable} must exit with status 0"
  files.list_split.each do |f|
    step "a#{opt_file_type} file #{f} must exist"
  end
end

Then /(.*) must fail gracefully/ do |executable|
  step "#{executable} must exit with status not 0"
  step "#{executable} must print a few lines on stderr"
end

Then /(.*) must (?:exit|terminate) gracefully/ do |executable|
  step "#{executable} must exit with status 0"
  step "#{executable} must print no line on stderr"
end

Given /(.*\.ramen) is compiled( as (.*))?/ do |source, opt_bin|
  default_bin = source[0..-(File.extname(source).length + 1)] + '.x'
  bin =
    if opt_bin.nil? then default_bin else opt_bin end
  if not File.exist? bin then
    `ramen compile #{source}`
    if bin != default_bin then
      `mv #{default_bin} #{bin}`
    end
  end
end

Given "ramen is started" do
  if $ramen_pid.nil?
    step "the environment variable RAMEN_PERSIST_DIR is set"
    # Cannot daemonize or we won't know the actual pid:
    $ramen_pid = Process.spawn('ramen start')
  end
end

Given "no worker must be running" do
  `ramen ps`.lines.length == 0
end

Given /(?:the )?workers? (.*) must( not)? be running/ do |workers, not_run|
  re = Regexp.union(workers.list_split.map{|w| /^#{w}\t/})
  l = `ramen ps`.lines.select{|e| e =~ re}.length
  if not_run
    expect(l).to be == 0
  else
    expect(l).to be > 0
  end
end

Given /(?:the )?programs? (.*) must( not)? be running/ do |programs, not_run|
  re = Regexp.union(programs.list_split.map{|w| /^#{w}\t/})
  l = `ramen ps --short`.lines.select{|e| e =~ re}.length
  if not_run
    expect(l).to be == 0
  else
    expect(l).to be > 0
  end
end

Given /no (?:program|worker)s? (?:is|are) running/ do
  `ramen ps --short`.lines.select{|e| e =~ /^([^\t]+)\t/}.each do |e|
    prog = $1
    `ramen kill "#{prog}"`
  end
end

Given /(?:the )?programs? (.*) (?:is|are) not running/ do |programs|
  re = Regexp.union(programs.list_split.map{|w| /^(#{w})\t/})
  l = `ramen ps --short`.lines.select{|e| e =~ re}.each do |e|
    prog = $1
    `ramen kill "#{prog}"`
  end
end

Given /(?:the )?programs? (.*) (?:is|are) running/ do |programs|
  running = `ramen ps --short`.lines.map do |l|
    l =~ /^([^\t]+)\t/
    $1
  end
  programs.list_split.each do |prog|
    if not running.include? prog
      `ramen run "#{prog}.x" 2>/dev/null`
    end
  end
end

Then /^after max (\d+) seconds (.+)$/ do |max_delay, what|
  # TODO: catch failures and retry
  step what
end