allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// 部分插件（file_picker → flutter_plugin_android_lifecycle）要求 compileSdk ≥ 36，
// 而插件自身按 34 编译。统一把所有 Android 库插件的 compileSdk 提升到 36。
// 必须在 afterEvaluate 里改：插件自己的 build 脚本会在配置阶段把 compileSdk 覆盖回 34。
subprojects {
    if (project.path == ":app") return@subprojects // :app 因 evaluationDependsOn 已评估完，不能再注册
    afterEvaluate {
        extensions.findByType(com.android.build.gradle.LibraryExtension::class.java)?.let {
            it.compileSdk = 36
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
