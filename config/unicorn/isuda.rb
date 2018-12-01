worker_processes 5
preload_app true
timeout 120

stderr_path File.absolute_path('/home/isucon/unicorn_stderr.log')
stdout_path File.absolute_path('/home/isucon/unicorn_stdout.log')
