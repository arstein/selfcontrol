#!/usr/bin/env ruby
# Slider freeze fix: add the extracted SCMinutesValueTransformer (+ its unit
# tests) to the right Xcode targets. Idempotent.
# Run from anywhere: GEM_PATH=/opt/homebrew/opt/cocoapods/libexec ruby scripts/slider_transformer_setup.rb
require 'xcodeproj'

Dir.chdir(File.expand_path('..', __dir__))

project = Xcodeproj::Project.open('SelfControl.xcodeproj')

def group_named(parent, name)
  return nil if parent.nil?
  parent.children.find { |child| child.respond_to?(:display_name) && child.display_name == name }
end

common = group_named(project.main_group, 'Common')
utility = group_named(common, 'Utility')
tests = group_named(project.main_group, 'SelfControlTests')
abort('expected project groups not found') unless common && utility && tests

files = {
  # transformer must be in the app (SCDurationSlider links it) and the tests
  'Common/Utility/SCMinutesValueTransformer.m' => [utility, %w[SelfControl SelfControlTests]],
  'SelfControlTests/SCMinutesValueTransformerTests.m' => [tests, %w[SelfControlTests]],
}

header_groups = {
  'Common/Utility/SCMinutesValueTransformer.h' => utility,
}

all_refs = project.files
header_groups.each do |path, group|
  basename = File.basename(path)
  group.new_file(basename) unless all_refs.any? { |ref| ref.real_path.to_s == File.expand_path(path) }
end

files.each do |path, (group, target_names)|
  ref = project.files.find { |candidate| candidate.real_path.to_s == File.expand_path(path) }
  ref ||= group.new_file(File.basename(path))
  target_names.each do |target_name|
    target = project.targets.find { |candidate| candidate.name == target_name }
    abort("target not found: #{target_name}") unless target
    next if target.source_build_phase.files_references.include?(ref)
    target.add_file_references([ref])
  end
end

project.save
puts 'OK: SCMinutesValueTransformer sources and tests added to project targets'
