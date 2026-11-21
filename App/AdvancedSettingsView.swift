import SwiftUI
import PhotosUI

/// 高级功能面板（对应 Android 首页「高级功能」五组：远程控制 / 小组件标题 / 高德 Key / 小组件样式 / 字体与图标 + 车图）
struct AdvancedSettingsView: View {
    @ObservedObject var st: AppState

    @State private var widgetTitle = Store.get(Store.kWidgetTitle)
    @State private var amapKey = Store.get(Store.kAmapUser)
    @State private var photoItem: PhotosPickerItem?
    @State private var ctrlMsg = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 远程控制
            sub("远程控制")
            HStack(spacing: 8) {
                ctrlBtn("锁车 / 解锁", "lock.fill") {
                    let locked = TspControl.heldLock() >= 0 ? TspControl.heldLock() == 1 : (TspControl.readCache()?.bool("locked", false) ?? false)
                    return TspControl.setDoor(!locked)
                }
                ctrlBtn("空调", "fanblades") { TspControl.toggle() }
                ctrlBtn("车窗", "rectangle.split.3x1") { TspControl.toggleWindow() }
                ctrlBtn("寻车", "iphone.radiowaves.left.and.right") { TspControl.find() }
            }
            if !ctrlMsg.isEmpty {
                Text(ctrlMsg).font(.caption).foregroundColor(.secondary)
            }

            // 小组件标题
            sub("小组件标题（留空显示车型）")
            HStack {
                TextField("标题", text: $widgetTitle)
                    .textFieldStyle(.roundedBorder)
                Button("保存") {
                    Store.set(Store.kWidgetTitle, widgetTitle.trimmingCharacters(in: .whitespaces))
                    WidgetBridge.reloadWidgets()
                }
            }

            // 高德 Key
            sub("高德地图 Key（选填，留空用内置）")
            HStack {
                TextField("Web 服务 Key", text: $amapKey)
                    .textFieldStyle(.roundedBorder)
                Button("保存") {
                    Store.set(Store.kAmapUser, amapKey.trimmingCharacters(in: .whitespaces))
                    Store.remove(Store.kGeoCache)
                    st.refresh()
                }
            }
            Text("申请：lbs.amap.com → 控制台 → 创建应用 → 添加 Key，服务平台必须选「Web 服务」")
                .font(.caption2).foregroundColor(.secondary)

            // 小组件样式
            sub("小组件样式")
            Picker("配色", selection: Binding(get: { Theme.raw }, set: { Store.set(Store.kWidgetTheme, $0); WidgetBridge.reloadWidgets() })) {
                Text("浅色").tag("light")
                Text("深色").tag("dark")
                Text("跟随系统").tag("auto")
            }
            .pickerStyle(.segmented)
            HStack {
                Text("圆角 \(Store.getInt(Store.kWidgetRadius, 22))")
                Slider(value: Binding(
                    get: { Double(Store.getInt(Store.kWidgetRadius, 22)) },
                    set: { Store.setInt(Store.kWidgetRadius, Int($0 / 2) * 2); WidgetBridge.reloadWidgets() }), in: 0...30, step: 2)
            }
            HStack {
                Text("不透明度 \(Store.getInt(Store.kWidgetAlpha, 100))%")
                Slider(value: Binding(
                    get: { Double(Store.getInt(Store.kWidgetAlpha, 100)) },
                    set: { Store.setInt(Store.kWidgetAlpha, Int($0 / 10) * 10); WidgetBridge.reloadWidgets() }), in: 20...100, step: 10)
            }
            HStack {
                Text("字号 \(Store.getInt(Store.kWidgetFontPct, 100))%")
                Slider(value: Binding(
                    get: { Double(Store.getInt(Store.kWidgetFontPct, 100)) },
                    set: { Store.setInt(Store.kWidgetFontPct, Int($0)); WidgetBridge.reloadWidgets() }), in: 70...150, step: 5)
            }

            // 车辆图片
            sub("车辆图片（自动识别车型，可自定义覆盖）")
            Text("当前车型：" + CarModel.label(CarModel.resolve(Session.shared.modelCode, Session.shared.vin, Session.shared.model))
                 + (Session.shared.color.isEmpty ? "" : " · " + Session.shared.color)
                 + (CarImages.hasCustom() ? " · 已自定义" : ""))
                .font(.caption).foregroundColor(.secondary)
            HStack {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Text("从相册选择")
                        .font(.subheadline)
                }
                if CarImages.hasCustom() {
                    Button("恢复默认") { CarImages.clearCustom() }
                        .font(.subheadline)
                }
            }
            .onChange(of: photoItem) { item in
                guard let item = item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let img = UIImage(data: data) {
                        CarImages.saveCustom(img)
                    }
                }
            }

            // 车控日志
            sub("车控日志")
            let logText = Store.get(Store.kCtrlLog)
            if logText.isEmpty {
                Text("暂无").font(.caption).foregroundColor(.secondary)
            } else {
                Text(logText)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func sub(_ t: String) -> some View {
        Text(t).font(.subheadline.bold()).padding(.top, 2)
    }

    private func ctrlBtn(_ title: String, _ icon: String, op: @escaping () -> TspControl.Res) -> some View {
        Button {
            ctrlMsg = "正在执行" + title + "…"
            DispatchQueue.global(qos: .userInitiated).async {
                let r = op()
                DispatchQueue.main.async {
                    ctrlMsg = r.msg
                    st.refresh()
                }
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.body)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.10)))
        }
        .buttonStyle(.plain)
    }
}
