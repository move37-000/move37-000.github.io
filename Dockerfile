# Alpine 대신 Debian 기반의 Ruby 이미지를 사용
FROM ruby:3.1-slim

# 필수 패키지 설치
RUN apt-get update && apt-get install -y \
    build-essential \
    git \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /srv/jekyll

# Jekyll 및 Bundler 설치
RUN gem install jekyll bundler

# 소스 복사 및 권한 설정
COPY . .

# Git 보안 설정 및 의존성 설치
RUN git config --global --add safe.directory /srv/jekyll && \
    rm -f Gemfile.lock && \
    bundle lock --add-platform x86_64-linux && \
    bundle install

EXPOSE 4000

CMD ["bundle", "exec", "jekyll", "serve", "--host", "0.0.0.0", "--port", "4000", "--force_polling"]