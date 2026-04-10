# Alpine 대신 Debian 기반의 Ruby 이미지를 사용
FROM ruby:3.1-slim

# 필수 패키지 설치
RUN apt-get update && apt-get install -y \
    build-essential \
    git \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /srv/jekyll

# 1. 모든 파일(Gemfile, .gemspec 포함)을 먼저 복사
COPY . .

# 2. 그 다음 설치 진행
RUN gem install jekyll bundler && \
    bundle install

# 3. Git 보안 설정 등 나머지 작업
RUN git config --global --add safe.directory /srv/jekyll && \
    bundle lock --add-platform x86_64-linux

EXPOSE 4000

CMD ["bundle", "exec", "jekyll", "serve", "--host", "0.0.0.0", "--port", "4000", "--force_polling"]