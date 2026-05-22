# frozen_string_literal: true

source "https://rubygems.org"

# 1. JSON 빌드 오류 방지
gem "json", ">= 2.7.2"

# 2. gemspec을 사용하지 않고 직접 젬을 명시합니다.
# (Chirpy 테마 구조상 로컬을 안 쓰시면 이 방식이 가장 안전합니다)
gem "jekyll-theme-chirpy", "~> 7.4"

gem "html-proofer", "~> 5.0", group: :test

platforms :mingw, :x64_mingw, :mswin, :jruby do
  gem "tzinfo", ">= 1", "< 3"
  gem "tzinfo-data"
end

gem "wdm", "~> 0.2.0", :platforms => [:mingw, :x64_mingw, :mswin]