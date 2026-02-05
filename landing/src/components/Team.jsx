import React from 'react'

import Thomas from '../img/Thomas.png?inline'
import Avaline from '../img/Avaline.png?inline'
import Khant from '../img/Khant.png?inline'
import Neil from '../img/Neil.png?inline'

const Team = () => {
  const teamMembers = [
    {
      name: "Thomas",
      role: "Lead Developer",
      image: Thomas,
      url: 'https://thomasbrillion.pro'
    },
    {
      name: "Avaline",
      role: "UI & Frontend Developer",
      image: Avaline,
      url: 'https://www.linkedin.com/in/myat-mon-avaline-5aa323186/'
    },
    {
      name: "Khant",
      role: "AI Engineer",
      image: Khant,
      url: 'https://www.linkedin.com/in/khin-khant-khant-hlaing/'
    },
    {
      name: "Neil",
      role: "Developer",
      image: Neil,
      url: 'https://www.linkedin.com/in/nay-m-b7a763297/'
    }
  ]

  return (
    <div className="bg-gray-50 py-20 px-8">
      <div className="max-w-7xl mx-auto">
        {/* Section Title */}
        <div className="text-center mb-16">
          <h2 className="font-fraunces text-4xl md:text-5xl lg:text-6xl font-black leading-tight mb-6">
            <span className="text-gray-900">Meet </span>
            <span className="bg-gradient-to-r from-brand-green to-brand-yellow bg-clip-text text-transparent">
              Our Team
            </span>
          </h2>
          <p className="font-poppins text-gray-600 text-lg md:text-xl max-w-3xl mx-auto">
            Dedicated professionals committed to your mental wellness journey
          </p>
        </div>

        {/* Team Grid */}
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-8">
          {teamMembers.map((member, index) => (
            <div key={index} onClick={() => window.open(member.url, '_blank')} className="bg-white rounded-3xl p-6 shadow-lg hover:shadow-xl hover:scale-105 transition-all duration-300 cursor-pointer">
              {/* Profile Image */}
              <div className="aspect-square mb-6 overflow-hidden rounded-2xl">
                <img 
                  src={member.image} 
                  alt={member.name}
                  className="w-full h-full object-cover"
                />
              </div>
              
              {/* Member Info */}
              <div className="text-center">
                <h3 className="font-fraunces text-xl font-black text-gray-900 mb-2">
                  {member.name}
                </h3>
                <p className="font-poppins text-gray-600 text-sm">
                  {member.role}
                </p>
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}

export default Team