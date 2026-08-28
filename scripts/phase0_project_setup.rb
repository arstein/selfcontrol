#!/usr/bin/env ruby
# Phase 0: swap signing to the fork owner's personal team, bump deployment
# target, and add a Copy Files phase that puts the daemon's launchd plist
# into Contents/Library/LaunchDaemons (required by SMAppService).
require 'xcodeproj'

team_id = ARGV[0]
abort("usage: ruby scripts/phase0_project_setup.rb TEAMID") unless team_id =~ /\A[A-Z0-9]{10}\z/

project = Xcodeproj::Project.open('SelfControl.xcodeproj')

update = lambda do |settings|
  settings['DEVELOPMENT_TEAM'] = team_id
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['CODE_SIGN_IDENTITY'] = 'Apple Development'
  settings['MACOSX_DEPLOYMENT_TARGET'] = '13.0'
  settings.delete('OTHER_CODE_SIGN_FLAGS')       # drops '-o library,hard,kill,runtime'
  settings.delete('PROVISIONING_PROFILE_SPECIFIER')
end

project.build_configurations.each { |c| update.call(c.build_settings) }
project.targets.each do |t|
  t.build_configurations.each { |c| update.call(c.build_settings) }
end

app_target = project.targets.find { |t| t.name == 'SelfControl' }
abort('SelfControl target not found') unless app_target

# Sign embedded Sparkle with our cert on copy, so it passes library validation
embed = app_target.copy_files_build_phases.find { |p| p.name == 'Embed Frameworks' }
if embed
  embed.files.each do |bf|
    bf.settings ||= {}
    bf.settings['ATTRIBUTES'] = ['CodeSignOnCopy', 'RemoveHeadersOnCopy']
  end
end

# Copy the daemon launchd plist into the bundle where SMAppService expects it
PHASE_NAME = 'Copy Daemon Launchd Plist'
unless app_target.copy_files_build_phases.any? { |p| p.name == PHASE_NAME }
  plist_ref = project.files.find { |f| f.path.to_s.end_with?('org.eyebeam.selfcontrold.plist') }
  plist_ref ||= project.new_file('Daemon/org.eyebeam.selfcontrold.plist')
  phase = app_target.new_copy_files_build_phase(PHASE_NAME)
  phase.dst_subfolder_spec = '1'                      # 1 = wrapper (bundle root)
  phase.dst_path = 'Contents/Library/LaunchDaemons'
  phase.add_file_reference(plist_ref)
end

project.save
puts "OK: team=#{team_id}, deployment target 13.0, daemon plist copy phase in place"
