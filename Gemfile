# frozen_string_literal: true

source "https://rubygems.org"

# 1. JSON 상수를 미리 로드하여 NameError 방지
gem "json", "2.7.2"

# 2. 문제의 sass-embedded를 안정적인 버전으로 강제 고정
gem "sass-embedded", "1.80.3"

# 3. 테마 및 의존성 설정
gem "jekyll-theme-chirpy", "~> 7.4"
gem "html-proofer", "~> 5.0", group: :test

platforms :mingw, :x64_mingw, :mswin, :jruby do
  gem "tzinfo", ">= 1", "< 3"
  gem "tzinfo-data"
end

gem "wdm", "~> 0.2.0", :platforms => [:mingw, :x64_mingw, :mswin]