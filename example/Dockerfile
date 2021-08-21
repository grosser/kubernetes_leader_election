FROM ruby:2-alpine

RUN apk add build-base

COPY Gemfile Gemfile.lock kubernetes_leader_election.gemspec ./
COPY lib/kubernetes_leader_election/version.rb lib/kubernetes_leader_election/version.rb
RUN bundle install

COPY lib lib

COPY example example

CMD ["bundle", "exec", "ruby", "example/app.rb"]
