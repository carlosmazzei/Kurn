//
//  ScreenshotSeedText+GermanChinese.swift
//  Kurn
//
//  German and Simplified Chinese seed text for App Store screenshots. See
//  `ScreenshotSeedText` for the shape every table follows.
//

#if DEBUG
import Foundation

extension ScreenshotSeedText {
    static let german = ScreenshotSeedText(
        language: .german,
        transcriptLanguage: "de-DE",
        templateName: "Allgemein",
        productFolder: "Produkt",
        roadmapTags: ["Roadmap", "Q3"],
        roadmapTitle: "Produkt-Roadmap-Abstimmung",
        roadmapLines: [
            "Fangen wir mit der Q3-Roadmap an. Ich will heute die drei wichtigsten Prioritäten festlegen.",
            "Einverstanden. In Kundengesprächen kommen Offline-Sync und der Export immer wieder.",
            "Ich übernehme den Export — einen Designentwurf aus dem letzten Sprint habe ich schon.",
            "Super. Priya, kannst du den Offline-Sync bis Freitag abschätzen?",
            "Ja, ich stimme mich mit dem Mobile-Team ab und habe bis dahin eine Schätzung.",
            "Eine offene Frage: Unterstützen wir das alte Importformat noch, oder fliegt es raus?",
            "Es fliegt raus — weniger als ein Prozent nutzt es, und es bremst den neuen Export.",
            "Klingt gut. Ich halte das als Entscheidung im Protokoll fest."
        ],
        roadmapFollowUp: [
            "Kurz noch — Sam, kannst du die Export-Mockups vor dem Review am Donnerstag teilen?",
            "Ja, ich lege sie heute Abend in den gemeinsamen Ordner."
        ],
        roadmapSections: [
            ScreenshotSeedSection(title: "Entscheidungen", items: [
                "Offline-Sync und Export sind die beiden wichtigsten Prioritäten in Q3.",
                "Das alte Importformat wird nicht mehr unterstützt."
            ]),
            ScreenshotSeedSection(title: "Aufgaben", items: [
                "Sam — Export-Design fertigstellen und Mockups vor Donnerstag teilen.",
                "Priya — Offline-Sync mit dem Mobile-Team bis Freitag abschätzen."
            ]),
            ScreenshotSeedSection(title: "Offene Fragen", items: [
                "Entfällt das alte Importformat in diesem oder im nächsten Release?"
            ])
        ],
        roadmapAttachmentName: "Roadmap Q3.pdf",
        roadmapAttachmentText: "Roadmap Q3: neues Onboarding, Offline-Sync, Preisseite.",
        designFolder: "Design",
        designTag: "UI",
        designTitle: "Design-Review",
        designLines: [
            "Zeig mir den neuen Export-Ablauf — zuerst will ich den leeren Zustand sehen.",
            "Klar. Solange es nichts zu exportieren gibt, zeigen wir eine kurze Erklärung und einen einzigen Button.",
            "Passt. Kann der Button dieselbe Akzentfarbe wie im Rest der App bekommen?",
            "Guter Punkt — ich passe es vor dem Review am Donnerstag an."
        ],
        designSections: [
            ScreenshotSeedSection(title: "Feedback", items: [
                "Der leere Zustand des Exports ist so freigegeben.",
                "Für den Haupt-Button die Akzentfarbe der App verwenden."
            ]),
            ScreenshotSeedSection(title: "Aufgaben", items: [
                "Jordan — Button-Farbe vor dem Review am Donnerstag anpassen."
            ])
        ],
        clientsFolder: "Kunden",
        onboardingTags: ["Onboarding", "Priorität"],
        onboardingTitle: "Kunden-Onboarding",
        onboardingLines: [
            "Willkommen — schauen wir uns an, wie euer Team Kurn im Alltag nutzt.",
            "Jedes Meeting bleibt auf dem Gerät, außer ihr schaltet die Cloud-Transkription ein."
        ],
        onboardingCheckIn: [
            "Kurze Nachfrage — gibt es Fragen, nachdem ihr es diese Woche ausprobiert habt?",
            "Nur eine — können wir zwei weitere Leute aus dem Team einladen?"
        ],
        onboardingSections: [
            ScreenshotSeedSection(title: "Zusammenfassung", items: [
                "Dem Kunden Aufnahme, Transkription und Zusammenfassungen auf dem Gerät gezeigt.",
                "Der Kunde fragte nach zwei weiteren Teammitgliedern."
            ]),
            ScreenshotSeedSection(title: "Aufgaben", items: [
                "Dem Kunden die Einladung für zwei weitere Plätze schicken."
            ])
        ],
        interviewTitle: "Kundeninterview",
        interviewLines: [
            "Erzählen Sie vom letzten Mal, als Sie Notizen aus einem alten Meeting suchen mussten.",
            "Ich habe zwanzig Minuten gebraucht, um herauszufinden, wer für eine Entscheidung von vor zwei Monaten zuständig war."
        ],
        interviewSummaryTitle: "Zusammenfassung",
        interviewSummary: "Der Kunde findet Entscheidungen und Zuständige aus früheren Meetings nur schwer; Suche und eine klare Aufgabenverfolgung sind die größten Wünsche.",
        standupTitle: "Wöchentliches Stand-up",
        standupLine: "Kurze Runde: Was wurde letzte Woche ausgeliefert, was ist blockiert?"
    )

    static let chinese = ScreenshotSeedText(
        language: .chinese,
        transcriptLanguage: "zh-Hans",
        templateName: "通用",
        productFolder: "产品",
        roadmapTags: ["路线图", "第三季度"],
        roadmapTitle: "产品路线图同步会",
        roadmapLines: [
            "先从第三季度路线图开始，今天我想定下前三个优先级。",
            "同意。客户电话里，离线同步和导出流程一直被提到。",
            "导出流程我来负责，上个迭代我已经有设计草稿了。",
            "很好。Priya，你能在周五前评估一下离线同步的工作量吗？",
            "可以，我和移动端团队一起看，到时给出粗略估算。",
            "还有个问题：旧的导入格式还要继续支持，还是可以去掉？",
            "去掉吧，使用率不到百分之一，而且拖慢了导出的重写。",
            "好的，我把这条作为决定记进会议纪要。"
        ],
        roadmapFollowUp: [
            "补充一下：Sam，周四评审前能分享导出流程的设计稿吗？",
            "可以，我今晚放到共享文件夹里。"
        ],
        roadmapSections: [
            ScreenshotSeedSection(title: "关键决定", items: [
                "离线同步和导出流程是第三季度的前两大优先事项。",
                "停止支持旧的导入格式。"
            ]),
            ScreenshotSeedSection(title: "待办事项", items: [
                "Sam：完成导出流程设计，并在周四前分享设计稿。",
                "Priya：周五前与移动端团队评估离线同步。"
            ]),
            ScreenshotSeedSection(title: "待定问题", items: [
                "旧导入格式在这个版本还是下个版本移除？"
            ])
        ],
        roadmapAttachmentName: "第三季度路线图.pdf",
        roadmapAttachmentText: "第三季度路线图：新手引导改版、离线同步、价格页面。",
        designFolder: "设计",
        designTag: "界面",
        designTitle: "设计评审",
        designLines: [
            "给我讲讲新的导出流程，我想先看空状态。",
            "好的。还没有可导出的内容时，我们显示一段简短说明和一个按钮。",
            "可以。按钮能和应用其他地方一样使用强调色吗？",
            "说得对，我会在周四评审前改好。"
        ],
        designSections: [
            ScreenshotSeedSection(title: "反馈", items: [
                "导出流程的空状态按现有设计通过。",
                "主按钮使用应用的强调色，而不是单独的颜色。"
            ]),
            ScreenshotSeedSection(title: "待办事项", items: [
                "Jordan：周四评审前修改按钮颜色。"
            ])
        ],
        clientsFolder: "客户",
        onboardingTags: ["新手引导", "优先"],
        onboardingTitle: "客户上手通话",
        onboardingLines: [
            "欢迎！我们来看看你的团队日常会怎样使用 Kurn。",
            "除非你主动开启云端转写，每场会议都只保存在设备上。"
        ],
        onboardingCheckIn: [
            "简单回访一下：这周试用后有什么问题吗？",
            "只有一个：能再邀请团队里的两个人吗？"
        ],
        onboardingSections: [
            ScreenshotSeedSection(title: "摘要", items: [
                "向客户演示了设备端录音、转写和摘要。",
                "客户询问能否再添加两名成员。"
            ]),
            ScreenshotSeedSection(title: "待办事项", items: [
                "给客户发送两个额外席位的邀请链接。"
            ])
        ],
        interviewTitle: "客户访谈",
        interviewLines: [
            "讲讲你上一次不得不翻找旧会议记录的经历。",
            "我花了二十分钟才查到两个月前的一个决定是谁负责的。"
        ],
        interviewSummaryTitle: "摘要",
        interviewSummary: "客户很难从过往会议中找到决定和负责人；搜索和清晰的待办跟踪是最主要的需求。",
        standupTitle: "每周站会",
        standupLine: "快速过一遍：上周上线了什么，什么被卡住了？"
    )
}
#endif
