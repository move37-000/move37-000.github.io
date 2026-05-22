# frozen_string_literal: true

source "https://rubygems.org"

# 1. JSON 관련 빌드 에러 방지를 위해 버전 고정
gem "json", ">= 2.7.2"

gemspec

# Chirpy 테마 사용 시 필요한 의존성 명시 (필요한 경우)
gem "jekyll-theme-chirpy", "~> 7.0"

gem "html-proofer", "~> 5.0", group: :test

platforms :mingw, :x64_mingw, :mswin, :jruby do
  gem "tzinfo", ">= 1", "< 3"
  gem "tzinfo-data"
end

gem "wdm", "~> 0.2.0", :platforms => [:mingw, :x64_mingw, :mswin]