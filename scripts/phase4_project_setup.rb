#!/usr/bin/env ruby
# Phase 4: add the pure override-decision layer (SCOverrideDecision) and
# its unit tests to the right Xcode targets. Idempotent. Mirrors
# scripts/phase1_project_setup.rb.
# Run from anywhere: GEM_PATH=/opt/homebrew/opt/cocoapods/libexec ruby scripts/phase4_project_setup.rb
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
  'Common/Utility/SCOverrideDecision.m' => [utility, %w[SelfControl selfcontrol-cli SCKillerHelper SelfControlTests org.eyebeam.selfcontrold]],
  'SelfControlTests/SCOverrideDecisionTests.m' => [tests, %w[SelfControlTests]],
}

header_groups = {
  'Common/Utility/SCOverrideDecision.h' => utility,
  'Common/SCOverrideConfig.h' => common,
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
puts 'OK: Phase 4 sources and tests added to project targets'
