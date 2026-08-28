source 'https://cdn.cocoapods.org/'

minVersion = '13.0'

platform :osx, minVersion

target "SelfControl" do
    use_frameworks! :linkage => :static
    pod 'MASPreferences', '~> 1.1.4'
    pod 'FormatterKit/TimeIntervalFormatter', '~> 1.8.0'
    pod 'LetsMove', '~> 1.24'

    # Add test target
    target 'SelfControlTests' do
        inherit! :complete
    end
end

post_install do |pi|
   pi.pods_project.targets.each do |t|
       t.build_configurations.each do |bc|
           if Gem::Version.new(bc.build_settings['MACOSX_DEPLOYMENT_TARGET']) < Gem::Version.new(minVersion)
               bc.build_settings['MACOSX_DEPLOYMENT_TARGET'] = minVersion
           end
       end
   end

   # CocoaPods 1.17 generates macOS framework resource paths without the
   # /Resources component (macOS frameworks nest resources under
   # Versions/Current/Resources, unlike iOS). Patch the generated copy script.
   Dir.glob('Pods/Target Support Files/**/*-resources.sh').each do |script|
       text = File.read(script)
       fixed = text.gsub(%r{\.framework/([A-Za-z0-9\-_]+\.lproj/)}, '.framework/Resources/\1')
       File.write(script, fixed) if fixed != text
   end
end
