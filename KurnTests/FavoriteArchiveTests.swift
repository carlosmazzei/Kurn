//
//  FavoriteArchiveTests.swift
//  KurnTests
//
//  Covers the new `Meeting.isFavorite` / `Meeting.archivedAt` state and the
//  `MeetingsLibraryBucket` predicate that drives the meetings list visibility.
//  These run against an in-memory `ModelContainer` so SwiftData persistence and
//  default values for the new lightweight-additive fields are exercised end to
//  end.
//

import Foundation
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct FavoriteArchiveTests {

    private func makeContext() -> ModelContext {
        ModelContext(TestModelContainer.make())
    }

    // MARK: - Default values

    @Test func newMeetingIsNeitherFavoriteNorArchived() {
        let meeting = Meeting(title: "Standup")
        #expect(meeting.isFavorite == false)
        #expect(meeting.archivedAt == nil)
        #expect(meeting.isArchived == false)
    }

    @Test func archivedAtIsPersistedAndReadBackThroughIsArchived() {
        let context = makeContext()
        let meeting = Meeting(title: "Standup")
        context.insert(meeting)
        meeting.archivedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try? context.save()
        #expect(meeting.isArchived == true)
        meeting.archivedAt = nil
        #expect(meeting.isArchived == false)
    }

    // MARK: - Bucket predicate

    @Test func allBucketHidesArchivedMeetings() {
        let active = Meeting(title: "Active")
        let archived = Meeting(title: "Archived")
        archived.archivedAt = Date()
        #expect(MeetingsLibraryBucket.all.contains(active) == true)
        #expect(MeetingsLibraryBucket.all.contains(archived) == false)
    }

    @Test func favoritesBucketShowsOnlyFavoritedActiveMeetings() {
        let plain = Meeting(title: "Plain")
        let favorite = Meeting(title: "Favorite")
        favorite.isFavorite = true
        let favoriteArchived = Meeting(title: "FavoriteArchived")
        favoriteArchived.isFavorite = true
        favoriteArchived.archivedAt = Date()
        #expect(MeetingsLibraryBucket.favorites.contains(plain) == false)
        #expect(MeetingsLibraryBucket.favorites.contains(favorite) == true)
        // Archived favorites are intentionally hidden from the Favorites bucket
        // — they live in the Archive bucket until the user restores them.
        #expect(MeetingsLibraryBucket.favorites.contains(favoriteArchived) == false)
    }

    @Test func archiveBucketShowsOnlyArchivedMeetings() {
        let active = Meeting(title: "Active")
        let archived = Meeting(title: "Archived")
        archived.archivedAt = Date()
        #expect(MeetingsLibraryBucket.archive.contains(active) == false)
        #expect(MeetingsLibraryBucket.archive.contains(archived) == true)
    }

    @Test func allCasesArePersistableViaRawValueRoundTrip() {
        for bucket in MeetingsLibraryBucket.allCases {
            #expect(MeetingsLibraryBucket(rawValue: bucket.rawValue) == bucket)
        }
    }
}
