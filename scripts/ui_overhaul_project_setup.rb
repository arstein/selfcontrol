#!/usr/bin/env ruby
# UI overhaul: keep the Xcode project in sync with UI/*.swift and the Swift
# unit tests. Idempotent - re-run after creating any new Swift file.
# Run: GEM_PATH=/opt/homebrew/opt/cocoapods/libexec ruby scripts/ui_overhaul_project_setup.rb
#      add --remove-legacy-ui to also drop the old window controllers (Task 10).
require 'xcodeproj'

Dir.chdir(File.expand_path('..', __dir__))
project = Xcodeproj::Project.open('SelfControl.xcodeproj')

app = project.targets.find { |t| t.name == 'SelfControl' } or abort('no SelfControl target')
tests = project.targets.find { |t| t.name == 'SelfControlTests' } or abort('no SelfControlTests target')

def group_named(parent, name)
  parent.children.find { |c| c.respond_to?(:display_name) && c.display_name == name }
end

def ref_for(project, group, path)
  project.files.find { |f| f.real_path.to_s == File.expand_path(path) } || group.new_file(File.basename(path))
end

def add_to(target, ref)
  target.add_file_references([ref]) unless target.source_build_phase.files_references.include?(ref)
end

# --- Swift UI sources -------------------------------------------------------
ui_group = group_named(project.main_group, 'UI') || project.main_group.new_group('UI', 'UI')
Dir.glob('UI/*.swift').sort.each do |path|
  ref = ref_for(project, ui_group, path)
  add_to(app, ref)
  add_to(tests, ref) if File.basename(path) == 'UIFormatting.swift' # pure Foundation logic, unit tested
end

# bridging header: reference only (not compiled)
ref_for(project, project.main_group, 'SelfControl-Bridging-Header.h')

# --- Swift unit tests ---------------------------------------------------------
tests_group = group_named(project.main_group, 'SelfControlTests') or abort('no SelfControlTests group')
Dir.glob('SelfControlTests/*.swift').sort.each do |path|
  add_to(tests, ref_for(project, tests_group, path))
end

# test target compiles Swift but needs no bridging header (UIFormatting is Foundation-only)
tests.build_configurations.each do |config|
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings.delete('SWIFT_OBJC_BRIDGING_HEADER')
end
app.build_configurations.each do |config|
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['SWIFT_OBJC_BRIDGING_HEADER'] = 'SelfControl-Bridging-Header.h'
end

# --- Task 10: remove the legacy window controllers -----------------------------
if ARGV.include?('--remove-legacy-ui')
  legacy_basenames = %w[
    TimerWindowController.h TimerWindowController.m TimerWindow.xib
    DomainListWindowController.h DomainListWindowController.m DomainList.xib DomainList.strings
    PreferencesGeneralViewController.h PreferencesGeneralViewController.m PreferencesGeneralViewController.xib
    PreferencesAdvancedViewController.h PreferencesAdvancedViewController.m PreferencesAdvancedViewController.xib
    SCTediumWindowController.h SCTediumWindowController.m
    ButtonWithPopupMenu.h ButtonWithPopupMenu.m
  ]
  removed = 0
  project.objects.select { |o| o.is_a?(Xcodeproj::Project::Object::PBXVariantGroup) || o.is_a?(Xcodeproj::Project::Object::PBXFileReference) }
         .select { |o| legacy_basenames.include?(o.display_name) }
         .each do |obj|
    project.targets.each do |t|
      [t.source_build_phase, t.resources_build_phase].compact.each do |phase|
        phase.files.select { |bf| bf.file_ref == obj }.each { |bf| phase.remove_build_file(bf); }
      end
    end
    obj.remove_from_project
    removed += 1
  end
  puts "removed #{removed} legacy UI references"
end

project.save
puts 'OK: UI overhaul project references in sync'
