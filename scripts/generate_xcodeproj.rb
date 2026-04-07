#!/usr/bin/env ruby

require 'fileutils'

begin
  require 'xcodeproj'
rescue LoadError
  warn 'Missing ruby gem `xcodeproj`. Install it with: gem install --user-install xcodeproj'
  exit 1
end

ROOT = File.expand_path('..', __dir__)
PROJECT_PATH = File.join(ROOT, 'NoType.xcodeproj')
APP_TARGET_NAME = 'NoType'
TEST_TARGET_NAME = 'NoTypeTests'
DEPLOYMENT_TARGET = '14.0'
APP_BUNDLE_ID = 'com.opensource.notype'
TEST_BUNDLE_ID = 'com.opensource.notype.tests'

def ensure_group(project, relative_dir)
  return project.main_group if relative_dir.nil? || relative_dir == '.'

  relative_dir.split('/').reduce(project.main_group) do |group, component|
    group.children.find { |child| child.isa == 'PBXGroup' && child.path == component } || group.new_group(component, component)
  end
end

def add_file_reference(project, relative_path)
  relative_dir = File.dirname(relative_path)
  group = ensure_group(project, relative_dir == '.' ? nil : relative_dir)
  existing = group.files.find { |file| file.path == File.basename(relative_path) } ||
    group.children.find { |child| child.respond_to?(:path) && child.path == File.basename(relative_path) }
  existing || group.new_file(File.basename(relative_path))
end

def each_file(root, pattern)
  Dir.glob(File.join(root, pattern)).sort.map do |absolute_path|
    absolute_path.delete_prefix("#{root}/")
  end
end

FileUtils.rm_rf(PROJECT_PATH)

project = Xcodeproj::Project.new(PROJECT_PATH)
project.root_object.attributes['LastUpgradeCheck'] = '2640'
project.root_object.attributes['TargetAttributes'] ||= {}

app_target = project.new_target(:application, APP_TARGET_NAME, :osx, DEPLOYMENT_TARGET)
test_target = project.new_target(:unit_test_bundle, TEST_TARGET_NAME, :osx, DEPLOYMENT_TARGET)
test_target.add_dependency(app_target)

project.root_object.attributes['TargetAttributes'][app_target.uuid] = {
  'CreatedOnToolsVersion' => '26.4'
}
project.root_object.attributes['TargetAttributes'][test_target.uuid] = {
  'CreatedOnToolsVersion' => '26.4',
  'TestTargetID' => app_target.uuid
}

app_target.build_configurations.each do |config|
  settings = config.build_settings
  settings['PRODUCT_NAME'] = APP_TARGET_NAME
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = APP_BUNDLE_ID
  settings['INFOPLIST_FILE'] = 'packaging/Info.plist'
  settings['GENERATE_INFOPLIST_FILE'] = 'NO'
  settings['SWIFT_VERSION'] = '6.0'
  settings['MACOSX_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['CURRENT_PROJECT_VERSION'] = '1'
  settings['MARKETING_VERSION'] = '1.0.0'
  settings['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/../Frameworks']
  settings['ENABLE_HARDENED_RUNTIME'] = 'YES'
  settings['ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS'] = 'NO'
end

test_target.build_configurations.each do |config|
  settings = config.build_settings
  settings['PRODUCT_NAME'] = TEST_TARGET_NAME
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = TEST_BUNDLE_ID
  settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  settings['SWIFT_VERSION'] = '6.0'
  settings['MACOSX_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/NoType.app/Contents/MacOS/NoType'
  settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
  settings['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/../Frameworks', '@loader_path/../Frameworks']
end

app_source_refs = each_file(ROOT, 'Sources/NoType/**/*.swift').map { |path| add_file_reference(project, path) }
test_source_refs = each_file(ROOT, 'Tests/NoTypeTests/**/*.swift').map { |path| add_file_reference(project, path) }
icon_ref = add_file_reference(project, 'packaging/NoTypeIcon.icns')
add_file_reference(project, 'packaging/Info.plist')

app_target.add_file_references(app_source_refs)
test_target.add_file_references(test_source_refs)
app_target.resources_build_phase.add_file_reference(icon_ref, true)

scheme = Xcodeproj::XCScheme.new
scheme.set_launch_target(app_target)
scheme.add_build_target(app_target)
scheme.add_test_target(test_target)
scheme.save_as(PROJECT_PATH, APP_TARGET_NAME, true)

project.save

puts "Generated #{PROJECT_PATH}"
