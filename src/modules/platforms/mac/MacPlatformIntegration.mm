/**************************************************************************
* Otter Browser: Web browser controlled by the user, not vice-versa.
* Copyright (C) 2015 - 2016 Michal Dutkiewicz aka Emdek <michal@emdek.pl>
*
* This program is free software: you can redistribute it and/or modify
* it under the terms of the GNU General Public License as published by
* the Free Software Foundation, either version 3 of the License, or
* (at your option) any later version.
*
* This program is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
* GNU General Public License for more details.
*
* You should have received a copy of the GNU General Public License
* along with this program.  If not, see <http://www.gnu.org/licenses/>.
*
**************************************************************************/

#include "MacPlatformIntegration.h"
#include "MacPlatformStyle.h"
#include "../../../core/ActionsManager.h"
#include "../../../core/Application.h"
#include "../../../core/NotificationsManager.h"
#include "../../../core/SettingsManager.h"
#include "../../../core/TransfersManager.h"
#include "../../../ui/MainWindow.h"
#include "../../../ui/Menu.h"

#include <QtCore/QDateTime>
#include <QtCore/QSysInfo>
#include <QtGui/QDesktopServices>

#import <AppKit/AppKit.h>
#import <Cocoa/Cocoa.h>

@interface MacPlatformIntegrationDockIconView : NSView
{
	double m_value;
}

- (void)setProgress:(double)value;
+ (MacPlatformIntegrationDockIconView*)getSharedDockIconView;

@end

static MacPlatformIntegrationDockIconView *getSharedDockIconView = nil;

@implementation MacPlatformIntegrationDockIconView

+ (MacPlatformIntegrationDockIconView*)getSharedDockIconView
{
	if (getSharedDockIconView == nil)
	{
		getSharedDockIconView = [[MacPlatformIntegrationDockIconView alloc] init];

		[[MacPlatformIntegrationDockIconView getSharedDockIconView] setProgress:-1];
	}

	return getSharedDockIconView;
}

- (void)setProgress:(double)value
{
	m_value = value;

	[[NSApp dockTile] display];
}

- (void)drawRect:(NSRect)dirtyRectangle
{
	Q_UNUSED(dirtyRectangle)

	NSRect boundary = [self bounds];

	[[NSApp applicationIconImage] drawInRect:boundary fromRect:NSZeroRect operation:NSCompositeCopy fraction:1.0];

	if (m_value < 0)
	{
		return;
	}

	NSRect rectangle = boundary;
	rectangle.size.height *= 0.13;
	rectangle.size.width *= 0.8;
	rectangle.origin.x = ((NSWidth(boundary) - NSWidth(rectangle)) / 2.0);
	rectangle.origin.y = (NSHeight(boundary) * 0.13);

	CGFloat radius = (rectangle.size.height / 2);
	NSBezierPath *bezierPath = [NSBezierPath bezierPathWithRoundedRect:rectangle xRadius:radius yRadius:radius];
	[bezierPath setLineWidth:2.0];

	[[NSColor grayColor] set];

	[bezierPath stroke];

	rectangle = NSInsetRect(rectangle, 2.0, 2.0);

	radius = (rectangle.size.height / 2.0);

	bezierPath = [NSBezierPath bezierPathWithRoundedRect:rectangle xRadius:radius yRadius:radius];
	[bezierPath setLineWidth:1.0];
	[bezierPath addClip];

	rectangle.size.width = floor(rectangle.size.width * m_value);

	[[NSColor colorWithSRGBRed:0.2 green:1 blue:0.2 alpha:1] set];

	NSRectFill(rectangle);
}

@end

@interface MacPlatformIntegrationUserNotificationCenterDelegate : NSObject<NSUserNotificationCenterDelegate>
{
	@public
		Otter::MacPlatformIntegration *m_platformIntegration;
}

- (id)initWithPlatformIntegration:(Otter::MacPlatformIntegration*)platformIntegration;
- (void)userNotificationCenter:(NSUserNotificationCenter*)center didActivateNotification:(NSUserNotification*)notification;
- (BOOL)userNotificationCenter:(NSUserNotificationCenter*)center shouldPresentNotification:(NSUserNotification*)notification;

@end

@implementation MacPlatformIntegrationUserNotificationCenterDelegate

-(id)initWithPlatformIntegration:(Otter::MacPlatformIntegration*)platformIntegration
{
	self = [super init];

	if (self)
	{
		m_platformIntegration = platformIntegration;

		[[NSUserNotificationCenter defaultUserNotificationCenter] setDelegate:self];
	}

	return self;
}

- (void)userNotificationCenter:(NSUserNotificationCenter*)center didActivateNotification:(NSUserNotification*)notification
{
	Q_UNUSED(center);

	m_platformIntegration->markNotificationClicked(QString::fromNSString(notification.identifier).toULongLong());
}

- (BOOL)userNotificationCenter:(NSUserNotificationCenter*)center shouldPresentNotification:(NSUserNotification*)notification
{
	Q_UNUSED(center);
	Q_UNUSED(notification);

	return YES;
}

@end

namespace Otter
{

MacPlatformIntegration::MacPlatformIntegration(Application *parent) : PlatformIntegration(parent),
	m_notificationIdentifier(0),
	m_notificationsWatcherTimer(0)
{
	[[MacPlatformIntegrationUserNotificationCenterDelegate alloc] initWithPlatformIntegration:this];
	[[NSApp dockTile] setContentView:[MacPlatformIntegrationDockIconView getSharedDockIconView]];

	Menu *menu(new Menu());
	menu->addAction(ActionsManager::NewTabAction);
	menu->addAction(ActionsManager::NewTabPrivateAction);
	menu->addAction(ActionsManager::NewWindowAction);
	menu->addAction(ActionsManager::NewWindowPrivateAction);
	menu->addSeparator();
	menu->addAction(ActionsManager::BookmarksAction)->setOverrideText(QT_TRANSLATE_NOOP("actions", "Bookmarks"));
	menu->addAction(ActionsManager::TransfersAction)->setOverrideText(QT_TRANSLATE_NOOP("actions", "Transfers"));
	menu->addAction(ActionsManager::HistoryAction)->setOverrideText(QT_TRANSLATE_NOOP("actions", "History"));
	menu->addAction(ActionsManager::NotesAction)->setOverrideText(QT_TRANSLATE_NOOP("actions", "Notes"));
	menu->setAsDockMenu();

	connect(TransfersManager::getInstance(), SIGNAL(transferChanged(Transfer*)), this, SLOT(updateTransfersProgress()));
	connect(TransfersManager::getInstance(), SIGNAL(transferStarted(Transfer*)), this, SLOT(updateTransfersProgress()));
	connect(TransfersManager::getInstance(), SIGNAL(transferFinished(Transfer*)), this, SLOT(updateTransfersProgress()));
	connect(TransfersManager::getInstance(), SIGNAL(transferRemoved(Transfer*)), this, SLOT(updateTransfersProgress()));
	connect(TransfersManager::getInstance(), SIGNAL(transferStopped(Transfer*)), this, SLOT(updateTransfersProgress()));
	connect(menu, SIGNAL(triggered(QAction*)), this, SLOT(triggerAction(QAction*)));
}

void MacPlatformIntegration::timerEvent(QTimerEvent *event)
{
	if (event->timerId() == m_notificationsWatcherTimer)
	{
		const int visibilityDuration(SettingsManager::getValue(SettingsManager::Interface_NotificationVisibilityDurationOption).toInt());
		QHash<quint64, NSUserNotification*> existingNotifications;

		for (NSUserNotification *notification in [[NSUserNotificationCenter defaultUserNotificationCenter] deliveredNotifications])
		{
			existingNotifications[QString::fromNSString(notification.identifier).toULongLong()] = notification;
		}

		const QList<quint64> allNotifications(m_notifications.keys());

		for (int i = 0; i < allNotifications.count(); ++i)
		{
			if (!existingNotifications.contains(allNotifications.at(i)))
			{
				m_notifications[allNotifications.at(i)]->markIgnored();

				m_notifications.remove(allNotifications.at(i));
			}
			else if (m_notifications[allNotifications.at(i)]->getCreationTime().secsTo(QDateTime::currentDateTime()) >= visibilityDuration)
			{
				[[NSUserNotificationCenter defaultUserNotificationCenter] removeDeliveredNotification:existingNotifications[allNotifications.at(i)]];

				m_notifications[allNotifications.at(i)]->markIgnored();

				m_notifications.remove(allNotifications.at(i));
			}
		}

		if (m_notifications.isEmpty())
		{
			killTimer(m_notificationsWatcherTimer);

			m_notificationsWatcherTimer = 0;
		}
	}
}

void MacPlatformIntegration::triggerAction(QAction *action)
{
	MainWindow *window(SessionsManager::getActiveWindow());
	Action *actionObject(qobject_cast<Action*>(action));

	if (window && actionObject)
	{
		window->triggerAction(actionObject->getIdentifier());
	}
}

void MacPlatformIntegration::markNotificationClicked(quint64 identifier)
{
	if (m_notifications.contains(identifier))
	{
		m_notifications[identifier]->markClicked();

		m_notifications.remove(identifier);
	}
}

void MacPlatformIntegration::runApplication(const QString &command, const QUrl &url) const
{
	if (command.isEmpty())
	{
		QDesktopServices::openUrl(url);
	}

///TODO
}

void MacPlatformIntegration::updateTransfersProgress()
{
	const QList<Transfer*> transfers(TransfersManager::getInstance()->getTransfers());
	qint64 bytesTotal(0);
	qint64 bytesReceived(0);
	int transferAmount(0);

	for (int i = 0; i < transfers.count(); ++i)
	{
		if (transfers[i]->getState() == Transfer::RunningState && transfers[i]->getBytesTotal() > 0)
		{
			++transferAmount;

			bytesTotal += transfers[i]->getBytesTotal();
			bytesReceived += transfers[i]->getBytesReceived();
		}
	}

	[[MacPlatformIntegrationDockIconView getSharedDockIconView] setProgress:((transferAmount > 0 && bytesTotal > 0) ? (static_cast<double>(bytesReceived) / bytesTotal) : -1)];
	[[[NSApplication sharedApplication] dockTile] setBadgeLabel:((transferAmount > 0) ? [NSString stringWithFormat:@"%d", transferAmount] : @"")];
}

void MacPlatformIntegration::showNotification(Notification *notification)
{
	if (QSysInfo::MacintoshVersion < QSysInfo::MV_10_8)
	{
		return;
	}

	QString title;

	switch (notification->getLevel())
	{
		case Notification::ErrorLevel:
			title = tr("Error");

			break;
		case Notification::WarningLevel:
			title = tr("Warning");

			break;
		default:
			title = tr("Information");

			break;
	}

	const quint64 identifier(++m_notificationIdentifier);

	m_notifications[identifier] = notification;

	NSUserNotification *nativeNotification = [[NSUserNotification alloc] init];
	nativeNotification.title = [NSString stringWithUTF8String:title.toUtf8().data()];
	nativeNotification.informativeText = [NSString stringWithUTF8String:notification->getMessage().toUtf8().data()];
	nativeNotification.identifier = [NSString stringWithUTF8String:QString::number(identifier).toUtf8().data()];

	[[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:nativeNotification];

	if (m_notificationsWatcherTimer == 0 && SettingsManager::getValue(SettingsManager::Interface_NotificationVisibilityDurationOption).toInt() > 0)
	{
		m_notificationsWatcherTimer = startTimer(1000);
	}
}

Style* MacPlatformIntegration::createStyle(const QString &name) const
{
	return new MacPlatformStyle(name);
}

QList<ApplicationInformation> MacPlatformIntegration::getApplicationsForMimeType(const QMimeType &mimeType)
{
	Q_UNUSED(mimeType)

///TODO

	return QList<ApplicationInformation>();
}

bool MacPlatformIntegration::canShowNotifications() const
{
	return (QSysInfo::MacintoshVersion >= QSysInfo::MV_10_8);
}

}
