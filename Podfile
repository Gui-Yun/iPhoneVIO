platform :ios, '17.2'

target 'iPhoneVIO' do
  use_frameworks!
  # No pods — using Network.framework (built-in)

  target 'iPhoneVIOTests' do
    inherit! :search_paths
  end

  target 'iPhoneVIOUITests' do
  end
  post_install do |installer|
    installer.generated_projects.each do |project|
        project.targets.each do |target|
            target.build_configurations.each do |config|
                config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '13.0'
            end
        end
    end
  end

end
