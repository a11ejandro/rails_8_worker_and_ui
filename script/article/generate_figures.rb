#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"

require_relative "../../config/environment"
require_relative "../../lib/article/figure_generator"

options = {
  durations: Rails.root.join("docs", "data", "durations_selected.csv").to_s,
  memory: Rails.root.join("docs", "data", "memory_selected.csv").to_s,
  out: Rails.root.join("docs", "figures").to_s
}

OptionParser.new do |opts|
  opts.banner = "Usage: script/article/generate_figures.rb [options]"
  opts.on("--durations PATH", "Path to durations_selected.csv") { |v| options[:durations] = v }
  opts.on("--memory PATH", "Path to memory_selected.csv") { |v| options[:memory] = v }
  opts.on("--out DIR", "Output directory (default: docs/figures)") { |v| options[:out] = v }
end.parse!

Article::FigureGenerator.generate!(
  durations_path: options[:durations],
  memory_path: options[:memory],
  out_dir: options[:out]
)
