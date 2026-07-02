FROM darroue/ruby:3.4.9
WORKDIR /root
EXPOSE 3000

RUN apt-get update \
  && apt-get install -y zip libreoffice \
  && rm -rf /var/lib/apt/lists/*

COPY Gemfile* /root
RUN bundle config --local without "development test" \
  && bundle config --local path "/vendor/bundle" \
  && bundle install

COPY --from=BACKEND /vendor/bundle /vendor/bundle
COPY ./ /root


RUN bundle config --local without "development test" \
  && bundle config --local path "/vendor/bundle" \
  && bundle config --local deployment "true"

CMD bundle exec foreman start