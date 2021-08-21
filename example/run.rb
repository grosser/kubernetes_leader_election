# frozen_string_literal: true
raise "run from base folder" if File.dirname(Dir.pwd) == "example"

def sh(command)
  puts command
  out = `#{command}`
  raise out unless $?.success?
  out
end

sh "docker build -f example/Dockerfile -t example ."
begin
  sh "kind create cluster --kubeconfig kindconfig.yml"
  sh "kind load docker-image example"
  sh "kubectl apply -f example/deployment.yml --kubeconfig kindconfig.yml"

  sleep 10
  out = sh "kubectl get pods --kubeconfig kindconfig.yml"
  raise out unless out.include?("Running")
  puts "Pods are running"

  sleep 30
  out = sh "kubectl logs --kubeconfig kindconfig.yml deploy/example"
  raise out unless out.include?("trying to become leader")
  puts "Done"
ensure
  sh "kind delete cluster --kubeconfig kindconfig.yml"
end
