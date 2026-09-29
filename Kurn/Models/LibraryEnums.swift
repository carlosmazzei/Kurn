//
//  LibraryEnums.swift
//  Kurn
//
//  How the meetings library is sorted and which meetings it shows.
//

import Foundation
import KurnCore
import SwiftData

/// How the meetings list is sorted. Date and title are stable database sorts;
/// duration is computed from related recordings so it is applied in memory.
enum MeetingsSortOrder: String, Codable, Sendable, CaseIterable, Identifiable {
    case dateNewest
    case dateOldest
    case titleAZ
    case durationLongest
    case durationShortest

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dateNewest: return NSLocalizedString("meetings.sort.date_newest", comment: "Newest first")
        case .dateOldest: return NSLocalizedString("meetings.sort.date_oldest", comment: "Oldest first")
        case .titleAZ: return NSLocalizedString("meetings.sort.title_az", comment: "Title A–Z")
        case .durationLongest: return NSLocalizedString("meetings.sort.duration_longest", comment: "Longest first")
        case .durationShortest: return NSLocalizedString("meetings.sort.duration_shortest", comment: "Shortest first")
        }
    }

    var systemImage: String {
        switch self {
        case .dateNewest, .dateOldest: return "calendar"
        case .titleAZ: return "textformat"
        case .durationLongest, .durationShortest: return "clock"
        }
    }

    /// Apply the chosen ordering to a list of meetings. The default
    /// `.dateNewest` is a no-op because `@Query` already sorts by `createdAt`
    /// descending; the other cases re-sort in memory (necessary for the
    /// computed `totalDuration`).
    func apply(to meetings: [Meeting]) -> [Meeting] {
        switch self {
        case .dateNewest:
            return meetings
        case .dateOldest:
            return meetings.sorted { $0.createdAt < $1.createdAt }
        case .titleAZ:
            return meetings.sorted {
                let lhs = $0.title.localizedCaseInsensitiveCompare($1.title)
                if lhs != .orderedSame { return lhs == .orderedAscending }
                return $0.createdAt > $1.createdAt
            }
        case .durationLongest:
            return meetings.sorted {
                if $0.totalDuration != $1.totalDuration { return $0.totalDuration > $1.totalDuration }
                return $0.createdAt > $1.createdAt
            }
        case .durationShortest:
            return meetings.sorted {
                if $0.totalDuration != $1.totalDuration { return $0.totalDuration < $1.totalDuration }
                return $0.createdAt > $1.createdAt
            }
        }
    }
}

/// Top-level library bucket selecting which meetings the list shows. Combines
/// with date filters and search; cannot itself be saved per-meeting. `.all` is
/// the inbox-style default and hides archived meetings; users see archived
/// meetings only when explicitly selecting `.archive`.
enum MeetingsLibraryBucket: String, Codable, Sendable, CaseIterable, Identifiable {
    case all
    case inbox
    case favorites
    case archive

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return NSLocalizedString("meetings.bucket.all", comment: "All meetings")
        case .inbox: return NSLocalizedString("meetings.bucket.inbox", comment: "Inbox")
        case .favorites: return NSLocalizedString("meetings.bucket.favorites", comment: "Favorites")
        case .archive: return NSLocalizedString("meetings.bucket.archive", comment: "Archive")
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "tray.full"
        case .inbox: return "tray"
        case .favorites: return "star.fill"
        case .archive: return "archivebox"
        }
    }

    /// Whether `meeting` belongs in this bucket given its current state.
    /// `.all` hides archived meetings; `.inbox` is meetings without a folder
    /// (also non-archived); `.favorites` is starred non-archived meetings;
    /// `.archive` is the only bucket that shows archived meetings.
    func contains(_ meeting: Meeting) -> Bool {
        switch self {
        case .all: return !meeting.isArchived
        case .inbox: return meeting.folder == nil && !meeting.isArchived
        case .favorites: return meeting.isFavorite && !meeting.isArchived
        case .archive: return meeting.isArchived
        }
    }
}

/// What the meetings list is currently showing: either a built-in bucket
/// (All / Favorites / Archive) or a user folder identified by its persistent
/// model id. Wrapped in one type so `MeetingsListView` keeps a single
/// `selection` state and one filter codepath for both. Archived meetings are
/// never visible from a folder selection — they stay in `Archive` until the
/// user restores them.
enum LibrarySelection: Hashable, Sendable {
    case bucket(MeetingsLibraryBucket)
    case folder(PersistentIdentifier)
    case smartFolder(UUID)

    static let allMeetings: LibrarySelection = .bucket(.all)
    static let inbox: LibrarySelection = .bucket(.inbox)

    /// Whether `meeting` matches this selection. `Inbox` (the synthetic bucket
    /// for meetings without a folder) and per-folder views both exclude
    /// archived meetings; `Archive` and `Favorites` work as on PR 2a.
    /// Smart folders apply their saved predicate.
    func contains(_ meeting: Meeting, smartFolderFilter: MeetingFilter? = nil) -> Bool {
        switch self {
        case .bucket(let bucket):
            return bucket.contains(meeting)
        case .folder(let id):
            guard !meeting.isArchived else { return false }
            return meeting.folder?.persistentModelID == id
        case .smartFolder:
            return smartFolderFilter?.matches(meeting) ?? false
        }
    }
}
