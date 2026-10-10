#!/usr/bin/env ruby
# Phase 6 (subdomain scoping): add new sources/tests to the right targets. Idempotent:
# files that don't exist yet are skipped, so re-run after creating each one.
# Run: GEM_PATH=/opt/homebrew/opt/cocoapods/libexec ruby scripts/phase6_project_setup.rb
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

# SCDomainScope needs SCBlockEntry.m (every target has it) and NSString+IPAddress.m
# (every target but SelfControl Killer and the test bundle, which lack it). The test bundle
# does not see the host app's category, so IPAddress.m is added to it below. Killer has no use
# for SCDomainScope and is left out.
scope_targets = %w[SelfControl selfcontrol-cli SCKillerHelper SelfControlTests org.eyebeam.selfcontrold]

sources = {
  'NSString+IPAddress.m' => [project.main_group, %w[SelfControlTests]],
  'Common/Utility/SCDomainScope.m' => [utility, scope_targets],
  'SelfControlTests/SCDomainScopeTests.m' => [tests, %w[SelfControlTests]],
  'SelfControlTests/SCSubdomainScopingTests.m' => [tests, %w[SelfControlTests]],
}
headers = {
  'Common/Utility/SCDomainScope.h' => utility,
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
puts 'OK: Phase 6 files synced to project targets'
