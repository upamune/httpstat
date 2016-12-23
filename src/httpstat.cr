require "./httpstat/*"
require "tempfile"
require "json"
require "colorize"
require "uri"

class Stat
  JSON.mapping({
    time_namelookup:    Float64,
    time_connect:       Float64,
    time_appconnect:    Float64,
    time_pretransfer:   Float64,
    time_redirect:      Float64,
    time_starttransfer: Float64,
    time_total:         Float64,
    speed_download:     Float64,
    speed_upload:       Float64,
    remote_ip:          String,
    remote_port:        String,
    local_ip:           String,
    local_port:         String,
  })
end

def fmta(t : Float64) : String
  sprintf("%7dms", t * 1000).colorize.cyan.to_s
end

def fmtb(t : Float64) : String
  sprintf("%-9s", (t*1000).to_i.to_s + "ms").colorize.cyan.to_s
end

def visit(url : String, args : Array(String))
  curl_format = <<-CURL
   {
  "time_namelookup": %{time_namelookup},
  "time_connect": %{time_connect},
  "time_appconnect": %{time_appconnect},
  "time_pretransfer": %{time_pretransfer},
  "time_redirect": %{time_redirect},
  "time_starttransfer": %{time_starttransfer},
  "time_total": %{time_total},
  "speed_download": %{speed_download},
  "speed_upload": %{speed_upload},
  "remote_ip": "%{remote_ip}",
  "remote_port": "%{remote_port}",
  "local_ip": "%{local_ip}",
  "local_port": "%{local_port}"
  }
  CURL

  prefix = "HTTPSTAT"
  show_body = ENV.fetch("#{prefix}_SHOW_BODY", "false") == "true" ? true : false
  show_ip = ENV.fetch("#{prefix}_SHOW_IP", "true") == "true" ? true : false
  show_speed = ENV.fetch("#{prefix}_SHOW_SPEED", "false") == "true" ? true : false
  save_body = ENV.fetch("#{prefix}_SAVE_BODY", "true") == "true" ? true : false
  curl_bin = ENV.fetch("#{prefix}_CURL_BIN", "curl")

  exclude_options = [
    "-w",
    "--write-out",
    "-D",
    "--dump-header",
    "-o",
    "--output",
    "-s",
    "--silent",
  ]

  exclude_options.each do |exclude_option|
    if args.index(exclude_option)
      err = sprintf("Error: %s is not allowed in extra curl args\n".colorize.yellow.to_s, exclude_option)
      STDERR.write(err.encode("UTF-8"))
      exit(1)
    end
  end

  headerf = Tempfile.new("header")
  bodyf = Tempfile.new("body")
  output = IO::Memory.new
  err = IO::Memory.new
  env = ENV.keys.zip(ENV.values).to_h
  env["LC_ALL"] = "C"
  args = ["-w", curl_format, "-D", headerf.path, "-o", bodyf.path, "-s", "-S"] + args + [url]
  status = Process.run(command: "curl", args: args, output: output, error: err, env: env)
  stat = Stat.from_json(output.to_s)

  http_template = <<-HTTP
  DNS Lookup   TCP Connection   Server Processing   Content Transfer
[%s  |     %s  |    %s      |       %s  ]
            |                |                   |                  |
   namelookup:%s      |                   |                  |
                       connect:%s         |                  |
                                     starttransfer:%s        |
                                                                total:%s
HTTP

  https_template = <<-HTTPS
  DNS Lookup   TCP Connection   TLS Handshake   Server Processing   Content Transfer
[%s  |     %s  |    %s  |        %s  |       %s  ]
            |                |               |                   |                  |
   namelookup:%s      |               |                   |                  |
                       connect:%s     |                   |                  |
                                   pretransfer:%s         |                  |
                                                     starttransfer:%s        |
                                                                                total:%s
HTTPS

  if show_ip
    printf("Connected to %s:%s from %s:%s\n\n",
      stat.remote_ip.colorize.cyan.to_s,
      stat.remote_port.colorize.cyan.to_s,
      stat.local_ip.colorize.cyan.to_s,
      stat.local_port.colorize.cyan.to_s)
  end

  headers = File.read(headerf.path).split("\r\n")
  headers.delete("")
  File.delete(headerf.path)
  headers.each_with_index do |header, i|
    if i == 0
      p1, p2 = header.split('/')
      puts(p1.colorize.green.to_s + "/".colorize.light_gray.to_s + p2.colorize.cyan.to_s)
    else
      if pos = header.index(':')
        puts(header[0..pos + 1].colorize.light_gray.to_s + header[pos + 2..header.size - 1].colorize.cyan.to_s)
      end
    end
  end
  print("\n")

  # body
  if show_body
    body = File.read(bodyf.path)
    body_limit = 1024
    body_size = body.size

    if body_size > body_limit
      puts(body[0..body_limit])
      puts()
      str = sprintf("%s is truncated (%s out of %s)", "Body".colorize.green.to_s, body_limit, body_size)

      if save_body
        str += sprintf(", stored in: %s\n", bodyf.path)
      end

      print(str)
    else
      puts(body)
    end
    puts()
  end

  if !save_body
    File.delete(bodyf.path)
  end

  case URI.parse(url).scheme
  when "http"
    res = sprintf(http_template,
      fmta(stat.time_namelookup),
      fmta(stat.time_connect - stat.time_namelookup),
      fmta(stat.time_starttransfer - stat.time_pretransfer),
      fmta(stat.time_total - stat.time_starttransfer),
      fmtb(stat.time_namelookup),
      fmtb(stat.time_connect),
      fmtb(stat.time_starttransfer),
      fmtb(stat.time_total))
    puts res
  when "https"
    res = sprintf(https_template,
      fmta(stat.time_namelookup),
      fmta(stat.time_connect - stat.time_namelookup),
      fmta(stat.time_pretransfer - stat.time_connect),
      fmta(stat.time_starttransfer - stat.time_pretransfer),
      fmta(stat.time_total - stat.time_starttransfer),
      fmtb(stat.time_namelookup),
      fmtb(stat.time_connect),
      fmtb(stat.time_pretransfer),
      fmtb(stat.time_starttransfer),
      fmtb(stat.time_total))
    puts res
  end

  if show_speed
    printf("speed_download: %.1f KiB/s, speed_upload: %.1f KiB/s\n\n",
      stat.speed_download.to_f / 1024.0,
      stat.speed_upload.to_f / 1024.0)
  end
end

def print_help
  help = <<-HELP
 Usage: httpstat URL [CURL_OPTIONS]
      httpstat -h | --help
      httpstat --version
 Arguments:
   URL     url to request, could be with or without `http(s)://` prefix
 Options:
   CURL_OPTIONS  any curl supported options, except for -w -D -o -S -s,
                 which are already used internally.
   -h --help     show this screen.
   --version     show version.
 Environments:
   HTTPSTAT_SHOW_BODY    Set to `true` to show response body in the output,
                         note that body length is limited to 1023 bytes, will be
                         truncated if exceeds. Default is `false`.
   HTTPSTAT_SHOW_IP      By default httpstat shows remote and local IP/port address.
                         Set to `false` to disable this feature. Default is `true`.
   HTTPSTAT_SHOW_SPEED   Set to `true` to show download and upload speed.
                         Default is `false`.
   HTTPSTAT_SAVE_BODY    By default httpstat stores body in a tmp file,
                         set to `false` to disable this feature. Default is `true`
   HTTPSTAT_CURL_BIN     Indicate the curl bin path to use. Default is `curl`
                         from current shell $PATH.
 HELP

  puts help
end

module Httpstat
  if ARGV.size == 0
    print_help()
    exit(0)
  end

  url = ARGV[0]
  help_options = ["-h", "--help"]

  if help_options.index(url)
    print_help()
    exit(0)
  end

  if url == "--version"
    printf("httpstat %s\n", VERSION)
    exit(0)
  end

  args = ARGV[1..ARGV.size - 1]

  visit(url, args)
end
