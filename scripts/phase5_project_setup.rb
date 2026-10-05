#!/usr/bin/env ruby
# Phase 5 (deep blocks): add new sources/tests to the right targets. Idempotent:
# files that don't exist yet are skipped, so re-run after creating each one.
# Run: GEM_PATH=/opt/homebrew/opt/cocoapods/libexec ruby scripts/phase5_project_setup.rb
require 'xcodeproj'

Dir.chdir(File.expand_path('..', __dir__))
project = Xcodeproj::Project.open('SelfControl.xcodeproj')

def group_named(parent, name)
  return nil if parent.nil?
  parent.children.find { |c| c.respond_to?(:display_name) && c.display_name == name }
end

common = group_named(project.main_group, 'Common')
utility = group_named(common, 'Utility')
tests = group_named(project.main_group, 'SelfControlTests')
abort('expected project groups not found') unless common && utility && tests

# Same targets as SCBlockUtilities.m, which depends on both.
everywhere = %w[SelfControl selfcontrol-cli SelfControl\ Killer SCKillerHelper SelfControlTests org.eyebeam.selfcontrold]

sources = {
  'Common/Utility/SCDeepBlockDecision.m' => [utility, everywhere],
  'Common/Utility/SCRuleCompiler.m' => [utility, everywhere],
  'SelfControlTests/SCAllowlistRegressionTests.m' => [tests, %w[SelfControlTests]],
  'SelfControlTests/SCDeepBlockDecisionTests.m' => [tests, %w[SelfControlTests]],
  'SelfControlTests/SCRuleCompilerTests.m' => [tests, %w[SelfControlTests]],
  'SelfControlTests/SCDeepBlockUtilitiesTests.m' => [tests, %w[SelfControlTests]],
}
headers = {
  'Common/Utility/SCDeepBlockDecision.h' => utility,
  'Common/Utility/SCRuleCompiler.h' => utility,
  'Common/SCDeepBlockConfig.h' => common,
  'SelfControlTests/SCPFTestSupport.h' => tests,
}

def ref_for(project, group, path)
  project.files.find { |f| f.real_path.to_s == File.expand_path(path) } || group.new_file(File.basename(path))
end

headers.each { |path, group| ref_for(project, group, path) if File.exist?(path) }
sources.each do |path, (group, target_names)|
  next unless File.exist?(path)
  ref = ref_for(project, group, path)
  target_names.each do |name|
    target = project.targets.find { |t| t.name == name } or abort("target not found: #{name}")
    target.add_file_references([ref]) unless target.source_build_phase.files_references.include?(ref)
  end
end

project.save
puts 'OK: Phase 5 files synced to project targets'
